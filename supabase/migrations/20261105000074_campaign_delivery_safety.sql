-- Campaign eligibility is checked at queue claim AND immediately before provider delivery.
alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_legacy;
create function private.inbox_delivery_error(p_message uuid)returns text
language plpgsql stable security definer set search_path=''as $$
declare m public.messages;c public.whatsapp_campaigns;cv public.conversations;why text;
begin
 why:=private.inbox_delivery_error_legacy(p_message);if why is not null then return why;end if;
 select *into m from public.messages where id=p_message;
 if not private.tenant_is_active(m.tenant_id)then return 'Hotel account is inactive.';end if;
 if m.campaign_id is null then return null;end if;
 select *into c from public.whatsapp_campaigns where id=m.campaign_id;
 if c.status not in('scheduled','running')or c.scheduled_at>now()then return 'Campaign is not eligible for dispatch.';end if;
 if not exists(select 1 from public.whatsapp_connections where id=(select connection_id from public.conversations where id=m.conversation_id)and phone_number_id=c.sender_phone_id and status='active')then return 'Campaign sender changed.';end if;
 if m.body is distinct from c.body or m.template_id is distinct from c.template_id or not exists(select 1 from public.message_templates where id=c.template_id and property_id=c.property_id and status='approved'and category='marketing'and campaign_supported and name=c.template_name and language=c.template_language and body=c.body)then return 'Campaign approved template changed.';end if;
 select *into cv from public.conversations where id=m.conversation_id;
 why:=private.campaign_contact_error(m.property_id,cv.wa_contact_id);if why is not null then return why;end if;
 if not exists(select 1 from public.whatsapp_campaign_recipients r join public.guests g on g.id=r.guest_id where r.campaign_id=c.id and r.message_id=m.id and r.wa_contact_id=cv.wa_contact_id and private.campaign_phone(g.phone)=r.wa_contact_id)then return 'Campaign guest phone changed or guest was removed.';end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid)from public,anon,authenticated;

-- Older workers cannot accidentally send campaigns. They retain ordinary inbox delivery only.
alter function public.claim_outbound_messages_v2(int)rename to claim_outbound_messages_v2_legacy;
revoke all on function public.claim_outbound_messages_v2_legacy(int)from public,anon,authenticated,service_role;
create function public.claim_outbound_messages_v3(p_limit int default 10,p_allow_campaigns boolean default false)
returns table(message_id uuid,phone_number_id text,credentials_ref text,wa_contact_id text,msg_type text,msg_body text,template_name text,template_language text,attempt int)
language plpgsql security definer set search_path=''as $$
begin
 update public.messages set status='failed',delivery_uncertain=true,locked_at=null,error='Delivery outcome unknown after worker interruption. Check provider status before sending again.'where direction='out'and status='sending'and locked_at<now()-interval '5 minutes';
 update public.messages m set status='failed',error=private.inbox_delivery_error(m.id),locked_at=null where m.direction='out'and m.status='queued'and m.next_attempt_at<=now()and(m.campaign_id is null or p_allow_campaigns)and private.inbox_delivery_error(m.id)is not null;
 return query with picked as(select m.id from public.messages m where m.direction='out'and m.status='queued'and m.next_attempt_at<=now()and m.attempts<5 and(m.campaign_id is null or p_allow_campaigns)
 order by m.created_at,m.id limit greatest(1,least(10,p_limit))for update skip locked),
 upd as(update public.messages m set status='sending',locked_at=now(),attempts=m.attempts+1 from picked where m.id=picked.id returning m.*)
 select u.id,wc.phone_number_id,wc.credentials_ref,cv.wa_contact_id,u.type,u.body,t.name,t.language,u.attempts from upd u join public.conversations cv on cv.id=u.conversation_id join public.whatsapp_connections wc on wc.id=cv.connection_id left join public.message_templates t on t.id=u.template_id;
end $$;
create function public.claim_outbound_messages_v2(p_limit int default 10)
returns table(message_id uuid,phone_number_id text,credentials_ref text,wa_contact_id text,msg_type text,msg_body text,template_name text,template_language text,attempt int)
language sql security definer set search_path=''as $$select *from public.claim_outbound_messages_v3(p_limit,false)$$;
revoke all on function public.claim_outbound_messages_v3(int,boolean),public.claim_outbound_messages_v2(int)from public,anon,authenticated;
grant execute on function public.claim_outbound_messages_v3(int,boolean),public.claim_outbound_messages_v2(int)to service_role;
-- Fence the original v1 worker entry point as well.
alter function public.claim_outbound_messages(int)rename to claim_outbound_messages_legacy;
revoke all on function public.claim_outbound_messages_legacy(int)from public,anon,authenticated,service_role;
create function public.claim_outbound_messages(p_limit int default 10)
returns table(message_id uuid,phone_number_id text,credentials_ref text,wa_contact_id text,msg_type text,msg_body text,template_name text,template_language text,attempt int)
language sql security definer set search_path=''as $$select *from public.claim_outbound_messages_v3(p_limit,false)$$;
revoke all on function public.claim_outbound_messages(int)from public,anon,authenticated;
grant execute on function public.claim_outbound_messages(int)to service_role;

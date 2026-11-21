-- Check consent and provider readiness when dequeuing, not just when composing.
create function private.inbox_delivery_error(p_message uuid) returns text
language plpgsql stable security definer set search_path='' as $$
declare m public.messages;c public.conversations;
begin
 select * into m from public.messages where id=p_message;
 if not found then return 'Message not found.';end if;
 select * into c from public.conversations where id=m.conversation_id;
 if private.is_opted_out(m.property_id,c.wa_contact_id) then return 'Contact opted out before delivery.';end if;
 if not exists(select 1 from public.whatsapp_connections where id=c.connection_id and status='active') then return 'WhatsApp connection is not active.';end if;
 if m.type='text' and (c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours') then return 'Reply window closed before delivery. Send an approved template.';end if;
 if m.type='template' and not exists(select 1 from public.message_templates where id=m.template_id and property_id=m.property_id and status='approved' and strpos(body,'{{')=0) then return 'Template is no longer eligible for delivery.';end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid) from public,anon,authenticated;

create function public.claim_outbound_messages_v2(p_limit int default 10)
returns table(message_id uuid,phone_number_id text,credentials_ref text,wa_contact_id text,msg_type text,msg_body text,template_name text,template_language text,attempt int)
language plpgsql security definer set search_path='' as $$
begin
 -- An abandoned HTTP attempt may already have sent. Never automatically resend it.
 update public.messages set status='failed',delivery_uncertain=true,locked_at=null,error='Delivery outcome unknown after worker interruption. Check provider status before sending again.'
 where direction='out' and status='sending' and locked_at<now()-interval '5 minutes';
 update public.messages m set status='failed',error=private.inbox_delivery_error(m.id),locked_at=null
 where m.direction='out' and m.status='queued' and m.next_attempt_at<=now() and private.inbox_delivery_error(m.id) is not null;
 return query
 with picked as(select m.id from public.messages m where m.direction='out' and m.status='queued' and m.next_attempt_at<=now() and m.attempts<5
 order by m.created_at,m.id limit greatest(1,least(10,p_limit)) for update skip locked),
 upd as(update public.messages m set status='sending',locked_at=now(),attempts=m.attempts+1 from picked where m.id=picked.id returning m.*)
 select u.id,wc.phone_number_id,wc.credentials_ref,c.wa_contact_id,u.type,u.body,t.name,t.language,u.attempts
 from upd u join public.conversations c on c.id=u.conversation_id join public.whatsapp_connections wc on wc.id=c.connection_id
 left join public.message_templates t on t.id=u.template_id;
end $$;

create function public.validate_outbound_claim(p_id uuid,p_attempt int) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare m public.messages;e text;
begin
 select * into m from public.messages where id=p_id;
 if not found or m.status<>'sending' or m.attempts<>p_attempt or m.locked_at<now()-interval '5 minutes' then return jsonb_build_object('ok',false,'error','Message claim expired or was replaced.');end if;
 e:=private.inbox_delivery_error(m.id);return jsonb_build_object('ok',e is null,'error',e);
end $$;

create function public.complete_outbound_message_v2(p_id uuid,p_attempt int,p_ok boolean,p_wa_id text default null,p_error text default null,p_retryable boolean default false,p_uncertain boolean default false) returns boolean
language plpgsql security definer set search_path='' as $$
declare m public.messages;
begin
 select * into m from public.messages where id=p_id for update;
 if not found or m.status<>'sending' or m.attempts<>p_attempt then return false;end if;
 if p_ok and nullif(trim(p_wa_id),'') is not null then
  perform public.complete_outbound_message(p_id,p_wa_id,true);return true;
 end if;
 update public.messages set status=case when p_retryable and not p_uncertain and attempts<5 then 'queued' else 'failed' end,
 delivery_uncertain=p_uncertain or p_ok,error=left(coalesce(p_error,'Delivery failed without a valid provider message ID.'),500),locked_at=null,
 next_attempt_at=case when p_retryable and not p_uncertain and attempts<5 then now()+make_interval(mins=>power(2,attempts)::int) else next_attempt_at end where id=m.id;
 return true;
end $$;
revoke all on function public.claim_outbound_messages_v2(int),public.validate_outbound_claim(uuid,int),public.complete_outbound_message_v2(uuid,int,boolean,text,text,boolean,boolean) from public,anon,authenticated;
grant execute on function public.claim_outbound_messages_v2(int),public.validate_outbound_claim(uuid,int),public.complete_outbound_message_v2(uuid,int,boolean,text,text,boolean,boolean) to service_role;

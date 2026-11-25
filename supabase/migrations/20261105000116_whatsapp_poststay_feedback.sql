-- Post-stay replies retain verified identity without reopening a completed stay.
create table public.whatsapp_guest_feedback(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,reservation_id uuid not null,guest_id uuid not null,
 kind text not null check(kind in('food','service','stay')),target_id uuid not null,rating integer not null check(rating between 1 and 5),comment text,
 conversation_id uuid not null references public.conversations(id),source_message_id uuid not null references public.messages(id),created_at timestamptz not null default now(),
 unique(property_id,kind,target_id),foreign key(property_id,tenant_id)references public.properties(id,tenant_id),foreign key(reservation_id,property_id)references public.reservations(id,property_id)
);
alter table public.whatsapp_guest_feedback enable row level security;
create policy feedback_read on public.whatsapp_guest_feedback for select to authenticated using(private.has_permission(property_id,'staff.manage')or private.has_permission(property_id,'reservations.read')or(kind='food'and private.has_permission(property_id,'orders.read'))or(kind='service'and(private.has_permission(property_id,'guest_requests.read')or private.has_permission(property_id,'guest_requests.manage'))));
revoke all on public.whatsapp_guest_feedback from public,anon,authenticated;grant select on public.whatsapp_guest_feedback to authenticated;grant all on public.whatsapp_guest_feedback to service_role;
create table private.whatsapp_feedback_followups(conversation_id uuid primary key references public.conversations(id),feedback_id uuid not null references public.whatsapp_guest_feedback(id),expires_at timestamptz not null default now()+interval '15 minutes');
revoke all on private.whatsapp_feedback_followups from public,anon,authenticated,service_role;
create function public.whatsapp_feedback_workspace(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if not(private.has_permission(p_property,'staff.manage')or private.has_permission(p_property,'reservations.read'))then raise exception 'Hotel access required.'using errcode='42501';end if;
 return jsonb_build_object('items',coalesce((select jsonb_agg(x order by created_at desc)from(select f.id,f.reservation_id,f.kind,f.target_id,f.rating,f.comment,f.created_at,g.full_name as guest_name from public.whatsapp_guest_feedback f join public.guests g on g.id=f.guest_id where f.property_id=p_property order by f.created_at desc limit 50)x),'[]'),'summary',(select jsonb_build_object('total',count(*),'average',round(avg(rating),1),'needs_attention',count(*)filter(where rating<=2))from public.whatsapp_guest_feedback where property_id=p_property));
end $$;
revoke all on function public.whatsapp_feedback_workspace(uuid)from public,anon;grant execute on function public.whatsapp_feedback_workspace(uuid)to authenticated;

create function private.poststay_reservation(p_conversation uuid)returns uuid language sql stable security definer set search_path=''as $$
 select r.id from public.conversations c join public.guests g on g.id=c.guest_id and private.campaign_phone(g.phone)=c.wa_contact_id join public.reservations r on r.guest_id=g.id and r.property_id=c.property_id
 where c.id=p_conversation and r.status='checked_out'and(exists(select 1 from public.whatsapp_guest_authorizations a where a.conversation_id=c.id and a.guest_id=g.id and a.wa_contact_id=c.wa_contact_id and a.status='granted')or exists(select 1 from private.whatsapp_booking_contacts b where b.reservation_id=r.id and b.guest_id=g.id and b.conversation_id=c.id and b.phone=c.wa_contact_id))
 and not exists(select 1 from public.reservations active where active.property_id=c.property_id and active.guest_id=g.id and active.status in('confirmed','checked_in')and active.check_out>=(now()at time zone(select timezone from public.properties where id=c.property_id))::date)
 order by r.checked_out_at desc nulls last,r.check_out desc,r.id limit 1
$$;

alter function private.handle_whatsapp_journey(uuid,uuid,text,text)rename to handle_whatsapp_journey_before_poststay;
revoke all on function private.handle_whatsapp_journey_before_poststay(uuid,uuid,text,text)from public,anon,authenticated,service_role;
create function private.handle_whatsapp_journey(p_conversation uuid,p_source uuid,p_command text,p_origin text)returns integer language plpgsql security definer set search_path=''as $$
#variable_conflict use_variable
declare c public.conversations;s public.whatsapp_journey_settings;r public.reservations;a private.whatsapp_journey_actions;rid uuid;poststay boolean:=false;action text;kind text;target uuid;score integer;fid uuid;body text;buttons jsonb:='[]';rows jsonb:='[]';payload jsonb;url text;token text;item record;follow private.whatsapp_feedback_followups;
begin
 select *into c from public.conversations where id=p_conversation for update;
 select *into s from public.whatsapp_journey_settings where property_id=c.property_id and enabled;
 if s.property_id is null or c.human_handoff or c.status<>'open'or c.last_inbound_at<now()-interval '24 hours'or c.last_inbound_at is null or private.is_opted_out(c.property_id,c.wa_contact_id)or not private.tenant_is_active(c.tenant_id)or not exists(select 1 from public.whatsapp_connections w join public.properties p on p.id=w.property_id where w.id=c.connection_id and w.status='active'and p.archived_at is null)then return 0;end if;
 rid:=private.journey_stay(c.id);if rid is null then rid:=private.poststay_reservation(c.id);poststay:=rid is not null;end if;
 action:=case p_command when'rate food'then'feedback_food'when'rate service'then'feedback_service'when'feedback'then'feedback_stay'when'review'then'post_review'when'bill'then'post_bill'when'reception'then'post_reception'else'post_menu'end;
 if p_command~'^journey:[a-f0-9-]{36}$'then
  select *into a from private.whatsapp_journey_actions where id=substring(p_command from 9)::uuid for update;
  if a.action not like'post_%'and a.action not like'feedback_%'then
   if not poststay then return private.handle_whatsapp_journey_before_poststay(c.id,p_source,p_command,p_origin);end if;
   action:='post_menu';
  else
   if a.id is null or a.consumed_at is not null or a.conversation_id<>c.id or a.phone<>c.wa_contact_id or a.connection_id<>c.connection_id then return 0;end if;
   if a.expires_at<=now()or a.settings_version<>s.version or a.reservation_id is distinct from rid then
    perform private.queue_journey_reply(c.id,p_source,'expired','This option expired or the stay changed. Send Hi for fresh options.',null);return 1;
   end if;
   action:=a.action;update private.whatsapp_journey_actions set consumed_at=clock_timestamp(),source_message_id=p_source where id=a.id;
  end if;
 end if;
 if rid is null then return private.handle_whatsapp_journey_before_poststay(c.id,p_source,p_command,p_origin);end if;
 select *into r from public.reservations where id=rid for update;
 -- Optional comments belong only to the just-rated item; ordinary menu commands never become comments.
 select *into follow from private.whatsapp_feedback_followups where conversation_id=c.id and expires_at>now();
 if follow.feedback_id is not null and p_command not like'journey:%'and lower(trim(regexp_replace((select msg.body from public.messages msg where msg.id=p_source and msg.type='text'),'[.!?[:space:]]+$','','g')))not in('hi','hello','hey','menu','start','checkout','check out','check-out','checkin','check in','food','services','stay','bill','documents','preferences','reception','human','agent','rate food','rate service','feedback','review')then
  update public.whatsapp_guest_feedback set comment=left((select msg.body from public.messages msg where msg.id=p_source),1000)where id=follow.feedback_id and guest_id=c.guest_id and conversation_id=c.id and comment is null;
  update public.guest_request_feedback legacy set comment=f.comment from public.whatsapp_guest_feedback f where f.id=follow.feedback_id and f.kind='service'and legacy.guest_request_id=f.target_id and legacy.recorded_via='guest';
  delete from private.whatsapp_feedback_followups where conversation_id=c.id;perform private.queue_journey_reply(c.id,p_source,'feedback_comment','Thank you. Your feedback has been shared with the hotel team. Send Hi for help.',null);return 1;
 end if;
 if action like'feedback_%'then
  if action in('feedback_food','feedback_service','feedback_stay')then
   kind:=substring(action from 10);
   if kind='stay'then target:=r.id;action:='feedback_target';
   else
    for item in select id,label from(select o.id,'Order '||upper(left(replace(o.id::text,'-',''),8))as label,o.created_at from public.orders o where kind='food'and o.reservation_id=r.id and o.status='served'and o.created_at>now()-interval '7 days'and not exists(select 1 from public.whatsapp_guest_feedback f where f.property_id=r.property_id and f.kind='food'and f.target_id=o.id)
     union all select q.id,left(q.title,24),q.created_at from public.guest_requests q where kind='service'and q.reservation_id=r.id and q.status='completed'and q.completed_at>now()-interval '7 days'and not exists(select 1 from public.whatsapp_guest_feedback f where f.property_id=r.property_id and f.kind='service'and f.target_id=q.id))x order by created_at desc,id limit 10 loop
     rows:=rows||jsonb_build_array(private.journey_button(c.id,r.id,'feedback_target',item.label,jsonb_build_object('kind',kind,'target',item.id)));
    end loop;
    body:=case when jsonb_array_length(rows)>0 then'Which completed item would you like to rate?'else'No completed items are waiting for feedback. Send Hi for other options.'end;
   end if;
  end if;
  if action in('feedback_target','feedback_score')then
   kind:=coalesce(kind,a.details->>'kind');target:=coalesce(target,(a.details->>'target')::uuid);
   if not(kind='stay'and target=r.id and r.status='checked_out' or kind='food'and exists(select 1 from public.orders where id=target and reservation_id=r.id and status='served')or kind='service'and exists(select 1 from public.guest_requests where id=target and reservation_id=r.id and status='completed'))then raise exception 'Feedback is available only for your completed stay, delivered food or completed request.'using errcode='22023';end if;
   if exists(select 1 from public.whatsapp_guest_feedback where property_id=r.property_id and whatsapp_guest_feedback.kind=kind and target_id=target)or(kind='service'and exists(select 1 from public.guest_request_feedback where guest_request_id=target))then body:='Your feedback for this item is already saved. Thank you. Send Hi for help.';
   elsif action='feedback_target'then
    body:=case kind when'food'then'How was your food order?'when'service'then'How was the completed service?'else'How was your stay?'end;
    buttons:=jsonb_build_array(private.journey_button(c.id,r.id,'feedback_score','Good',jsonb_build_object('kind',kind,'target',target,'rating',5)),private.journey_button(c.id,r.id,'feedback_score','Okay',jsonb_build_object('kind',kind,'target',target,'rating',3)),private.journey_button(c.id,r.id,'feedback_score','Needs attention',jsonb_build_object('kind',kind,'target',target,'rating',1)));
   else
    score:=(a.details->>'rating')::integer;
    insert into public.whatsapp_guest_feedback(tenant_id,property_id,reservation_id,guest_id,kind,target_id,rating,conversation_id,source_message_id)values(r.tenant_id,r.property_id,r.id,r.guest_id,kind,target,score,c.id,p_source)on conflict on constraint whatsapp_guest_feedback_property_id_kind_target_id_key do nothing returning id into fid;
    if fid is not null and kind='service'then insert into public.guest_request_feedback(tenant_id,property_id,guest_request_id,rating,recorded_via)values(r.tenant_id,r.property_id,target,score,'guest')on conflict(guest_request_id)do nothing;end if;
    if fid is not null then insert into private.whatsapp_feedback_followups(conversation_id,feedback_id)values(c.id,fid)on conflict(conversation_id)do update set feedback_id=excluded.feedback_id,expires_at=now()+interval '15 minutes';end if;
    body:='Thank you. Your rating is saved. You may reply with a comment, or send Hi for the menu.';
   end if;
  end if;
 elsif poststay then
  if action='post_bill'then
   if not private.whatsapp_public_link(p_origin)or p_origin~'[?#]'or p_origin~'/s/'then raise exception 'Secure bill address unavailable. Reception can help.'using errcode='22023';end if;
   token:=encode(extensions.gen_random_bytes(32),'hex');insert into public.guest_access_tokens(tenant_id,property_id,reservation_id,token_hash,expires_at)values(r.tenant_id,r.property_id,r.id,encode(sha256(convert_to(token,'utf8')),'hex'),now()+interval '24 hours');url:=rtrim(p_origin,'/')||'/s/'||token||'/bill?via=whatsapp';
   body:='View your completed stay’s bill securely. This does not reopen your stay.';payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','cta_url','body',jsonb_build_object('text',body),'action',jsonb_build_object('name','cta_url','parameters',jsonb_build_object('display_text','My bill / receipt','url',url))));
  elsif action='post_review'then
   select data->>'review_url'into url from public.whatsapp_guest_settings where property_id=r.property_id;
   if not coalesce(private.whatsapp_public_link(url),false)then body:='Reception can help you share feedback. You can also choose Share feedback in the menu.';
   else body:='Thank you for staying with us. You are welcome to share an honest review of your experience.';payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','cta_url','body',jsonb_build_object('text',body),'action',jsonb_build_object('name','cta_url','parameters',jsonb_build_object('display_text','Leave a review','url',url))));end if;
  elsif action in('post_reception','post_support','post_booking')or p_command in('human','agent')then
   body:=case action when'post_booking'then'Reception will help you with a new booking enquiry.'when'post_support'then'Reception will help with your completed stay or lost item.'else'Reception has been notified and will reply here.'end;
   perform private.queue_journey_reply(c.id,p_source,'handoff',body,null);update public.conversations set human_handoff=true,version=version+1 where id=c.id;return 1;
  else
   body:='Thank you for staying at '||(select name from public.properties where id=r.property_id)||'. Your stay has ended. How can we help?';
   rows:=jsonb_build_array(private.journey_button(c.id,r.id,'post_bill','My bill / receipt'),private.journey_button(c.id,r.id,'feedback_stay','Share feedback'),private.journey_button(c.id,r.id,'post_review','Leave a review'),private.journey_button(c.id,r.id,'post_support','Lost item / support'),private.journey_button(c.id,r.id,'post_booking','Book another stay'),private.journey_button(c.id,r.id,'post_reception','Talk to reception'));
  end if;
 else return private.handle_whatsapp_journey_before_poststay(c.id,p_source,p_command,p_origin);
 end if;
 if jsonb_array_length(buttons)>0 then payload:=private.journey_buttons_payload(body,buttons);elsif jsonb_array_length(rows)>0 then payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','list','body',jsonb_build_object('text',body),'action',jsonb_build_object('button','Choose an option','sections',jsonb_build_array(jsonb_build_object('title','Guest help','rows',rows)))));end if;
 perform private.queue_journey_reply(c.id,p_source,action,body,payload);return 1;
end $$;
revoke all on function private.handle_whatsapp_journey(uuid,uuid,text,text),private.poststay_reservation(uuid)from public,anon,authenticated,service_role;
-- Let explicit rating requests bypass the unrelated-message debounce.
do $$declare d text;begin d:=pg_get_functiondef('public.dispatch_whatsapp_guest_replies(integer,text)'::regprocedure);d:=replace(d,'''human'',''agent'')','''human'',''agent'',''rate food'',''rate service'',''feedback'',''review'')');execute d;end $$;
-- The old inbound matcher only considered open stays. Retain an existing verified
-- conversation identity for post-stay help, never infer one from a phone match alone.
create function private.restore_poststay_identity(p_conversation uuid)returns void language plpgsql security definer set search_path=''as $$declare c public.conversations;gid uuid;begin
 select *into c from public.conversations where id=p_conversation for update;if c.guest_id is not null then return;end if;
 select a.guest_id into gid from public.whatsapp_guest_authorizations a join public.guests g on g.id=a.guest_id and private.campaign_phone(g.phone)=c.wa_contact_id
 where a.property_id=c.property_id and a.conversation_id=c.id and a.wa_contact_id=c.wa_contact_id and a.status='granted'and exists(select 1 from public.reservations r where r.property_id=c.property_id and r.guest_id=a.guest_id and r.status='checked_out');
 if gid is null or exists(select 1 from public.reservations r join public.guests g on g.id=r.guest_id join public.properties p on p.id=r.property_id where r.property_id=c.property_id and r.status in('confirmed','checked_in')and r.check_out>=(now()at time zone p.timezone)::date and private.campaign_phone(g.phone)=c.wa_contact_id)then return;end if;
 update public.conversations set guest_id=gid where id=c.id;
end $$;
revoke all on function private.restore_poststay_identity(uuid)from public,anon,authenticated,service_role;
do $$declare d text;begin
 d:=pg_get_functiondef('public.ingest_whatsapp_inbound(text,text,text,text,text,text,text,jsonb,timestamp with time zone)'::regprocedure);d:=replace(d,' cmd:=lower',E' if cid is not null then perform private.restore_poststay_identity(cid);end if;\n cmd:=lower');execute d;
end $$;

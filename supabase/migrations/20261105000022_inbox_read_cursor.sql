-- Match read cursors to the same (created_at,id) ordering used by history.
alter table public.conversation_reads add column last_read_id uuid not null default '00000000-0000-0000-0000-000000000000';
update public.conversation_reads cr set last_read_id=coalesce((select id from public.messages where conversation_id=cr.conversation_id and direction='in' and created_at<=cr.last_read_at order by created_at desc,id desc limit 1),'00000000-0000-0000-0000-000000000000'::uuid);
create or replace function public.inbox_workspace(p_property uuid,p_filters jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;selected public.conversations;conn public.whatsapp_connections;cursor_row public.messages;
 q text:=left(trim(coalesce(p_filters->>'q','')),100);view_status text:=coalesce(p_filters->>'status','open');assignment text:=coalesce(p_filters->>'assignment','all');
 pg int:=greatest(1,least(100000,coalesce((p_filters->>'page')::int,1)));can_manage boolean;can_assign boolean;latest_visible uuid;
begin
 if not private.has_permission(p_property,'whatsapp.use') then raise exception 'not permitted' using errcode='42501';end if;
 can_manage:=private.has_permission(p_property,'staff.manage');
 can_assign:=can_manage or private.has_permission(p_property,'tasks.assign');
 select * into conn from public.whatsapp_connections where property_id=p_property;
 with filtered as materialized(
 select c.*,person.full_name as assignee_name,coalesce(m.body,'['||m.type||']') as preview,
  (select count(*) from public.messages im left join public.conversation_reads cr on cr.conversation_id=im.conversation_id and cr.user_id=auth.uid()
   where im.conversation_id=c.id and im.direction='in' and (im.created_at,im.id)>(coalesce(cr.last_read_at,'-infinity'::timestamptz),coalesce(cr.last_read_id,'00000000-0000-0000-0000-000000000000'::uuid))) as unread
 from public.conversations c left join public.profiles person on person.id=c.assigned_to
 left join lateral(select body,type from public.messages where conversation_id=c.id order by created_at desc,id desc limit 1)m on true
 where c.property_id=p_property and (q='' or strpos(lower(concat_ws(' ',c.contact_name,c.wa_contact_id)),lower(q))>0)
 and(view_status='all' or c.status=view_status)
 and(case assignment when 'mine' then c.assigned_to=auth.uid() when 'unassigned' then c.assigned_to is null else true end)
 and(coalesce(p_filters->>'handoff','')<>'human' or c.human_handoff)
 ) select jsonb_build_object('total',(select count(*) from filtered),'page',pg,'conversations',coalesce((select jsonb_agg(to_jsonb(x)) from(select * from filtered order by last_message_at desc,id desc limit 25 offset(pg-1)*25)x),'[]'::jsonb)) into result;
 if nullif(p_filters->>'c','') is not null then select * into selected from public.conversations where id=(p_filters->>'c')::uuid and property_id=p_property;
 else select c.* into selected from public.conversations c where c.id=(result#>>'{conversations,0,id}')::uuid;end if;
 result:=result||jsonb_build_object('can_manage',can_manage,'can_assign',can_assign,'user_id',auth.uid(),
 'connection',case when conn.id is null then null else jsonb_build_object('id',conn.id,'display_phone',conn.display_phone,'status',conn.status,'phone_number_id',case when can_manage then conn.phone_number_id end,'waba_id',case when can_manage then conn.waba_id end) end,
 'stats',(select jsonb_build_object('open',count(*) filter(where status='open'),'mine',count(*) filter(where status='open' and assigned_to=auth.uid()),'unassigned',count(*) filter(where status='open' and assigned_to is null)) from public.conversations where property_id=p_property),
 'failed',(select count(*) from public.messages where property_id=p_property and direction='out' and status='failed'),
 'templates',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'language',language,'body',body,'supported',strpos(body,'{{')=0) order by name,language) from public.message_templates where property_id=p_property and status='approved'),'[]'::jsonb),
 'assignees',case when can_assign then coalesce((select jsonb_agg(jsonb_build_object('id',m.user_id,'name',coalesce(pr.full_name,pr.email,'Team member')) order by pr.full_name) from public.tenant_memberships m join public.profiles pr on pr.id=m.user_id
 where m.tenant_id=(select tenant_id from public.properties where id=p_property) and private.inbox_eligible_user(p_property,m.user_id)),'[]'::jsonb) else '[]'::jsonb end);
 if selected.id is null then return result||jsonb_build_object('current',null,'messages','[]'::jsonb);end if;
 if nullif(p_filters->>'before','') is not null then
  select * into cursor_row from public.messages where id=(p_filters->>'before')::uuid and conversation_id=selected.id;
  if not found then raise exception 'History cursor no longer belongs to this conversation. Open latest messages.' using errcode='22023';end if;
 end if;
 result:=result||jsonb_build_object('current',to_jsonb(selected)||jsonb_build_object('assignee_name',(select full_name from public.profiles where id=selected.assigned_to),
 'opted_out',private.is_opted_out(p_property,selected.wa_contact_id),'window_open',selected.last_inbound_at>=now()-interval '24 hours',
 'window_ends_at',selected.last_inbound_at+interval '24 hours','consent',(select status from public.consent_records where property_id=p_property and wa_contact_id=selected.wa_contact_id order by recorded_at desc,id desc limit 1)),
 'messages',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at,x.id) from(select m.id,m.direction,m.type,m.body,m.status,m.error,m.attempts,m.delivery_uncertain,m.wa_message_id,m.created_at,m.next_attempt_at,t.name as template_name,t.language as template_language
 from public.messages m left join public.message_templates t on t.id=m.template_id where m.conversation_id=selected.id
 and(cursor_row.id is null or (m.created_at,m.id)<(cursor_row.created_at,cursor_row.id)) order by m.created_at desc,m.id desc limit 50)x),'[]'::jsonb));
 result:=result||jsonb_build_object('has_older',exists(select 1 from public.messages m where m.conversation_id=selected.id and (m.created_at,m.id)<
 ((result#>>'{messages,0,created_at}')::timestamptz,(result#>>'{messages,0,id}')::uuid)));
 return result;
end $$;

create or replace function public.inbox_mark_read(p_conversation uuid,p_message uuid) returns void
language plpgsql security definer set search_path='' as $$
declare c public.conversations;through_at timestamptz;
begin
 select * into c from public.conversations where id=p_conversation;
 if not found or not private.has_permission(c.property_id,'whatsapp.use') then raise exception 'not permitted' using errcode='42501';end if;
 select created_at into through_at from public.messages where id=p_message and conversation_id=c.id and direction='in';
 if not found then raise exception 'Incoming message not found.' using errcode='22023';end if;
 insert into public.conversation_reads(conversation_id,user_id,tenant_id,property_id,last_read_at,last_read_id) values(c.id,auth.uid(),c.tenant_id,c.property_id,through_at,p_message)
 on conflict(conversation_id,user_id) do update set last_read_at=case when (excluded.last_read_at,excluded.last_read_id)>(public.conversation_reads.last_read_at,public.conversation_reads.last_read_id) then excluded.last_read_at else public.conversation_reads.last_read_at end,
 last_read_id=case when (excluded.last_read_at,excluded.last_read_id)>(public.conversation_reads.last_read_at,public.conversation_reads.last_read_id) then excluded.last_read_id else public.conversation_reads.last_read_id end;
end $$;

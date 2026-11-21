alter table public.conversations add column version integer not null default 1;
alter table public.messages add column creation_request_id uuid,add column delivery_uncertain boolean not null default false;
create unique index messages_request_id on public.messages(conversation_id,creation_request_id) where creation_request_id is not null;
create function private.conversation_version() returns trigger language plpgsql set search_path='' as $$
begin new.version:=old.version+1;return new;end $$;
revoke all on function private.conversation_version() from public,anon,authenticated;
create trigger conversations_version before update on public.conversations for each row execute function private.conversation_version();
create table public.conversation_reads(
 conversation_id uuid not null,user_id uuid not null references public.profiles(id) on delete cascade,
 tenant_id uuid not null,property_id uuid not null,last_read_at timestamptz not null,
 primary key(conversation_id,user_id),
 foreign key(conversation_id,property_id) references public.conversations(id,property_id) on delete cascade,
 foreign key(property_id,tenant_id) references public.properties(id,tenant_id) on delete cascade
);
alter table public.conversation_reads enable row level security;
create policy conversation_reads_own on public.conversation_reads for select to authenticated
 using(user_id=(select auth.uid()) and private.has_permission(property_id,'whatsapp.use'));

create function private.inbox_eligible_user(p_property uuid,p_user uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.properties p join public.tenant_memberships m on m.tenant_id=p.tenant_id
 where p.id=p_property and m.user_id=p_user and (m.role in ('owner','admin') or exists(
 select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id=ur.role_id
 where ur.property_id=p_property and ur.user_id=p_user and rp.permission_key='whatsapp.use')))
$$;
revoke all on function private.inbox_eligible_user(uuid,uuid) from public,anon,authenticated;

create function public.inbox_workspace(p_property uuid,p_filters jsonb default '{}') returns jsonb
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
   where im.conversation_id=c.id and im.direction='in' and im.created_at>coalesce(cr.last_read_at,'-infinity'::timestamptz)) as unread
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

create function public.inbox_mark_read(p_conversation uuid,p_message uuid) returns void
language plpgsql security definer set search_path='' as $$
declare c public.conversations;through_at timestamptz;
begin
 select * into c from public.conversations where id=p_conversation;
 if not found or not private.has_permission(c.property_id,'whatsapp.use') then raise exception 'not permitted' using errcode='42501';end if;
 select created_at into through_at from public.messages where id=p_message and conversation_id=c.id and direction='in';
 if not found then raise exception 'Incoming message not found.' using errcode='22023';end if;
 insert into public.conversation_reads(conversation_id,user_id,tenant_id,property_id,last_read_at) values(c.id,auth.uid(),c.tenant_id,c.property_id,through_at)
 on conflict(conversation_id,user_id) do update set last_read_at=greatest(public.conversation_reads.last_read_at,excluded.last_read_at);
end $$;

create function public.inbox_manage(p_conversation uuid,p_version int,p_action text,p_user uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare c public.conversations;manager boolean;target uuid;
begin
 c:=private.lock_conversation(p_conversation,'whatsapp.use');
 if c.version is distinct from p_version then raise exception 'This conversation changed. Refresh before continuing.' using errcode='40001';end if;
 manager:=private.has_permission(c.property_id,'tasks.assign') or private.has_permission(c.property_id,'staff.manage');
 if p_action='claim' then
  if c.assigned_to is not null and c.assigned_to<>auth.uid() then raise exception 'This conversation already belongs to another teammate. Ask a manager to reassign it.' using errcode='22023';end if;
  target:=auth.uid();
 elsif p_action='assign' then
  if not manager then raise exception 'not permitted' using errcode='42501';end if;target:=p_user;
 elsif p_action='release' then
  if c.assigned_to is distinct from auth.uid() and not manager then raise exception 'not permitted' using errcode='42501';end if;
  target:=null;
 elsif p_action='close' then update public.conversations set status='closed' where id=c.id;return;
 elsif p_action='reopen' then update public.conversations set status='open' where id=c.id;return;
 elsif p_action in ('human_on','human_off') then update public.conversations set human_handoff=(p_action='human_on') where id=c.id;return;
 else raise exception 'Unknown conversation action.' using errcode='22023';end if;
 if target is not null then
  if not private.inbox_eligible_user(c.property_id,target) then raise exception 'Choose a teammate with WhatsApp access to this hotel.' using errcode='22023';end if;
  insert into public.property_memberships(tenant_id,property_id,user_id) values(c.tenant_id,c.property_id,target) on conflict do nothing;
 end if;
 update public.conversations set assigned_to=target where id=c.id;
end $$;

create function public.inbox_send(p_conversation uuid,p_request uuid,p_body text default null,p_template uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare c public.conversations;m uuid;t public.message_templates;conn_status text;
begin
 c:=private.lock_conversation(p_conversation,'whatsapp.use');
 if p_request is null then raise exception 'Reload the reply form and try again.' using errcode='22023';end if;
 select id into m from public.messages where conversation_id=c.id and creation_request_id=p_request;
 if found then return m;end if;
 select status into conn_status from public.whatsapp_connections where id=c.connection_id;
 if conn_status is distinct from 'active' then raise exception 'WhatsApp messaging is not enabled for this hotel.' using errcode='22023';end if;
 if c.status<>'open' then raise exception 'Reopen the conversation before replying.' using errcode='22023';end if;
 if private.is_opted_out(c.property_id,c.wa_contact_id) then raise exception 'This contact opted out. Messaging is blocked until they opt in again.' using errcode='22023';end if;
 if p_template is not null then
  select * into t from public.message_templates where id=p_template and property_id=c.property_id and status='approved';
  if not found then raise exception 'Choose an approved template for this hotel.' using errcode='22023';end if;
  if strpos(t.body,'{{')>0 then raise exception 'Templates with variables are not supported yet.' using errcode='22023';end if;
 else
  if length(trim(coalesce(p_body,''))) not between 1 and 4096 then raise exception 'Write a reply between 1 and 4096 characters.' using errcode='22023';end if;
  if c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours' then raise exception 'The reply window has closed. Choose an approved template.' using errcode='22023';end if;
 end if;
 insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,template_id,status,sent_by,creation_request_id)
 values(c.tenant_id,c.property_id,c.id,'out',case when p_template is null then 'text' else 'template' end,case when p_template is null then trim(p_body) else t.body end,p_template,'queued',auth.uid(),p_request) returning id into m;
 update public.conversations set last_message_at=now() where id=c.id;
 return m;
end $$;

create function public.inbox_retry(p_message uuid) returns void
language plpgsql security definer set search_path='' as $$
declare m public.messages;c public.conversations;t public.message_templates;
begin
 select * into m from public.messages where id=p_message for update;
 if not found or not private.has_permission(m.property_id,'whatsapp.use') then raise exception 'not permitted' using errcode='42501';end if;
 select * into c from public.conversations where id=m.conversation_id;
 if m.direction<>'out' or m.status<>'failed' or m.delivery_uncertain or m.wa_message_id is not null then raise exception 'Delivery cannot be safely retried here. Check the provider status before sending again.' using errcode='22023';end if;
 if c.status<>'open' or private.is_opted_out(c.property_id,c.wa_contact_id) or not exists(select 1 from public.whatsapp_connections where id=c.connection_id and status='active') then raise exception 'Reopen the conversation and check connection and consent before retrying.' using errcode='22023';end if;
 if m.type='text' and (c.last_inbound_at is null or c.last_inbound_at<now()-interval '24 hours') then raise exception 'The reply window has closed. Send an approved template instead.' using errcode='22023';end if;
 if m.template_id is not null and not exists(select 1 from public.message_templates where id=m.template_id and property_id=m.property_id and status='approved' and strpos(body,'{{')=0) then raise exception 'Template is no longer available.' using errcode='22023';end if;
 update public.messages set status='queued',attempts=0,error=null,next_attempt_at=now(),locked_at=null where id=m.id;
end $$;

create function public.inbox_configure(p_property uuid,p_phone_id text,p_waba_id text,p_display text,p_credentials_ref text,p_status text default 'pending') returns void
language plpgsql security definer set search_path='' as $$
declare tenant uuid;c public.whatsapp_connections;
begin
 if not private.has_permission(p_property,'staff.manage') then raise exception 'not permitted' using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property for update;
 if p_phone_id is null or p_phone_id!~'^[0-9]{5,30}$' or p_waba_id is null or p_waba_id!~'^[0-9]{5,30}$' or length(trim(coalesce(p_credentials_ref,''))) not between 1 and 100 or length(coalesce(p_display,''))>40 or p_status is null or p_status not in ('pending','active','disabled') then raise exception 'Check the number IDs, credential reference, and connection status.' using errcode='22023';end if;
 select * into c from public.whatsapp_connections where property_id=p_property for update;
 if c.id is not null and (c.phone_number_id<>p_phone_id or c.waba_id<>p_waba_id) and exists(select 1 from public.conversations where connection_id=c.id) then raise exception 'This connection has conversation history. Its business number cannot be replaced here.' using errcode='22023';end if;
 insert into public.whatsapp_connections(tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref,status)
 values(tenant,p_property,p_phone_id,p_waba_id,nullif(trim(p_display),''),trim(p_credentials_ref),p_status)
 on conflict(property_id) do update set phone_number_id=excluded.phone_number_id,waba_id=excluded.waba_id,display_phone=excluded.display_phone,credentials_ref=excluded.credentials_ref,status=excluded.status;
end $$;

revoke all on function public.inbox_workspace(uuid,jsonb),public.inbox_mark_read(uuid,uuid),public.inbox_manage(uuid,int,text,uuid),public.inbox_send(uuid,uuid,text,uuid),public.inbox_retry(uuid),public.inbox_configure(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.inbox_workspace(uuid,jsonb),public.inbox_mark_read(uuid,uuid),public.inbox_manage(uuid,int,text,uuid),public.inbox_send(uuid,uuid,text,uuid),public.inbox_retry(uuid),public.inbox_configure(uuid,text,text,text,text,text) to authenticated;

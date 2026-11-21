-- Provider synchronization must verify the entire text-only template definition, not just its body.
alter table public.message_templates add column campaign_supported boolean not null default false;
create table public.whatsapp_marketing_permissions(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,wa_contact_id text not null,
 status text not null check(status in('granted','revoked')),evidence text not null check(length(trim(evidence))between 5 and 1000),
 actor_id uuid not null references public.profiles(id),recorded_at timestamptz not null default clock_timestamp(),
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade
);
create index on public.whatsapp_marketing_permissions(property_id,wa_contact_id,recorded_at desc,id desc);
create table public.whatsapp_campaigns(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,name text not null check(length(name)between 2 and 120),
 body text not null check(length(body)between 1 and 4096),filters jsonb not null,selected_guests jsonb not null default '[]',selection_mode text not null check(selection_mode in('all','selected')),
 template_id uuid references public.message_templates(id),template_name text,template_language text,sender_phone_id text,
 status text not null default 'draft'check(status in('draft','scheduled','running','completed','cancelled','blocked')),
 scheduled_at timestamptz,schedule_timezone text,version int not null default 1,last_error text,
 created_by uuid references public.profiles(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade
);
create table public.whatsapp_campaign_recipients(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,campaign_id uuid not null references public.whatsapp_campaigns(id)on delete cascade,
 guest_id uuid references public.guests(id)on delete set null,wa_contact_id text not null,guest_name text not null,
 state text not null default 'pending'check(state in('pending','queued','skipped')),skip_reason text,message_id uuid references public.messages(id)on delete set null,
 unique(campaign_id,wa_contact_id)
);
alter table public.messages add column campaign_id uuid references public.whatsapp_campaigns(id)on delete set null;
create index on public.messages(campaign_id)where campaign_id is not null;
create table private.whatsapp_campaign_commands(
 property_id uuid not null references public.properties(id)on delete cascade,request_id uuid not null,actor_id uuid not null,
 payload jsonb not null,result uuid not null,created_at timestamptz not null default now(),primary key(property_id,request_id)
);
revoke all on private.whatsapp_campaign_commands from public,anon,authenticated;
do $$declare n text;begin foreach n in array array['whatsapp_marketing_permissions','whatsapp_campaigns','whatsapp_campaign_recipients']loop
 execute format('alter table public.%I enable row level security',n);
 execute format('create policy campaign_managers on public.%I for select to authenticated using(private.has_permission(property_id,''staff.manage''))',n);
 execute format('create policy platform_account_active on public.%I as restrictive for all to authenticated using(private.tenant_is_active(tenant_id))with check(private.tenant_is_active(tenant_id))',n);
 end loop;end $$;
create function private.campaign_phone(p_phone text)returns text language sql immutable set search_path=''as $$
 select case when p_phone~'^\+[0-9 ()-]+$'and regexp_replace(p_phone,'[^0-9]','','g')~'^[1-9][0-9]{7,14}$'then regexp_replace(p_phone,'[^0-9]','','g')end
$$;
create function private.campaign_contact_error(p_property uuid,p_phone text)returns text
language sql stable security definer set search_path=''as $$
 select case when p_phone is null then 'Missing or invalid international phone'
 when private.is_opted_out(p_property,p_phone)then 'Contact opted out'
 when coalesce((select status from public.whatsapp_marketing_permissions where property_id=p_property and wa_contact_id=p_phone order by recorded_at desc,id desc limit 1),'unknown')<>'granted'then 'Marketing permission not recorded'
 when exists(select 1 from public.conversations where property_id=p_property and wa_contact_id=p_phone and(human_handoff or status='closed'))then 'Conversation requires staff review'
 end
$$;
revoke all on function private.campaign_phone(text),private.campaign_contact_error(uuid,text)from public,anon,authenticated;

create function private.campaign_audience(p_property uuid,p_filters jsonb,p_selected jsonb default null)
returns table(guest_id uuid,guest_name text,phone text,last_departure date,stays bigint,exclusion text)
language plpgsql stable security definer set search_path=''as $$
declare from_day date;to_day date;state text;src text;q text;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object'or pg_column_size(p_filters)>2000 then raise exception 'Invalid audience filters.'using errcode='22023';end if;
 from_day:=nullif(p_filters->>'from','')::date;to_day:=nullif(p_filters->>'to','')::date;
 state:=coalesce(p_filters->>'status','checked_out');src:=coalesce(p_filters->>'source','all');q:=lower(trim(coalesce(p_filters->>'q','')));
 if(state not in('all','confirmed','checked_in','checked_out'))or src not in('all','direct','walk_in','ota')or length(q)>100 or(from_day is not null and to_day is not null and from_day>to_day)then raise exception 'Check audience dates and filters.'using errcode='22023';end if;
 if p_selected is not null and(jsonb_typeof(p_selected)<>'array'or jsonb_array_length(p_selected)>2000)then raise exception 'Select at most 2000 guests.'using errcode='22023';end if;
 return query with matches as(
 select g.id,g.full_name,private.campaign_phone(g.phone)as normalized,max(r.check_out)last_date,count(*)stay_count
 from public.guests g join public.reservations r on r.guest_id=g.id
 where r.property_id=p_property and r.status in('confirmed','checked_in','checked_out')and(state='all'or r.status=state)and(src='all'or r.source=src)
 and(from_day is null or r.check_out>from_day)and(to_day is null or r.check_in<=to_day)
 and(q=''or strpos(lower(g.full_name||' '||coalesce(g.phone,'')),q)>0)
 and(p_selected is null or g.id::text in(select jsonb_array_elements_text(p_selected)))
 group by g.id,g.full_name,g.phone
 ),dedup as(select distinct on(coalesce(m.normalized,m.id::text))m.*from matches m order by coalesce(m.normalized,m.id::text),m.id)
 select d.id,d.full_name,d.normalized,d.last_date,d.stay_count,private.campaign_contact_error(p_property,d.normalized)from dedup d;
end $$;
revoke all on function private.campaign_audience(uuid,jsonb,jsonb)from public,anon,authenticated;

create function public.campaign_audience(p_property uuid,p_filters jsonb,p_page int default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 with audience as materialized(select *from private.campaign_audience(p_property,p_filters))
 select jsonb_build_object('total',(select count(*)from audience),'eligible',(select count(*)from audience where exclusion is null),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from audience order by guest_name,guest_id limit 30 offset(greatest(1,least(p_page,10000))-1)*30)x),'[]'::jsonb))into result;
 return result;
end $$;

create function public.record_marketing_permission(p_property uuid,p_guest uuid,p_status text,p_evidence text)returns void
language plpgsql security definer set search_path=''as $$
declare phone text;tenant uuid;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 select g.tenant_id,private.campaign_phone(g.phone)into tenant,phone from public.guests g where g.id=p_guest and exists(select 1 from public.reservations where guest_id=g.id and property_id=p_property);
 if phone is null or p_status is null or p_status not in('granted','revoked')or p_evidence is null or length(trim(p_evidence))not between 5 and 1000 then raise exception 'Choose a hotel guest with an international phone and record permission evidence (5–1000 characters).'using errcode='22023';end if;
 insert into public.whatsapp_marketing_permissions(tenant_id,property_id,wa_contact_id,status,evidence,actor_id)values(tenant,p_property,phone,p_status,trim(p_evidence),auth.uid());
end $$;

create function public.save_whatsapp_campaign(p_property uuid,p_request uuid,p_id uuid,p_version int,p_data jsonb)returns uuid
language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_campaigns;previous private.whatsapp_campaign_commands;result uuid;tenant uuid;payload jsonb;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or jsonb_typeof(p_data)is distinct from 'object'or pg_column_size(p_data)>100000 then raise exception 'Invalid campaign form.'using errcode='22023';end if;
 payload:=jsonb_build_object('id',p_id,'version',p_version,'data',p_data);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('campaign-save:'||p_property::text||p_request::text,0));
 select *into previous from private.whatsapp_campaign_commands where property_id=p_property and request_id=p_request;
 if found then if previous.actor_id<>auth.uid()or previous.payload<>payload then raise exception 'Request already used.'using errcode='22023';end if;return previous.result;end if;
 if length(trim(coalesce(p_data->>'name','')))not between 2 and 120 or length(trim(coalesce(p_data->>'body','')))not between 1 and 4096 or coalesce(p_data->>'selection_mode','')not in('all','selected')then raise exception 'Enter a campaign name, message and audience selection.'using errcode='22023';end if;
 perform count(*)from private.campaign_audience(p_property,p_data->'filters',case when p_data->>'selection_mode'='selected'then p_data->'selected_guests'else null end);
 if p_data->>'selection_mode'='selected'and(jsonb_typeof(p_data->'selected_guests')is distinct from 'array'or jsonb_array_length(p_data->'selected_guests')<1)then raise exception 'Select at least one guest.'using errcode='22023';end if;
 if p_id is not null then
 select *into c from public.whatsapp_campaigns where id=p_id and property_id=p_property for update;
 if not found or c.status<>'draft'or c.version is distinct from p_version then raise exception 'Campaign changed or is no longer a draft.'using errcode='40001';end if;
 end if;
 select tenant_id into tenant from public.properties where id=p_property;
 if nullif(p_data->>'template_id','')is not null and not exists(select 1 from public.message_templates where id=(p_data->>'template_id')::uuid and property_id=p_property and category='marketing')then raise exception 'Choose a marketing template from this hotel.'using errcode='22023';end if;
 if p_id is null then
 insert into public.whatsapp_campaigns(tenant_id,property_id,name,body,filters,selected_guests,selection_mode,template_id,created_by)
 values(tenant,p_property,trim(p_data->>'name'),p_data->>'body',p_data->'filters',coalesce(p_data->'selected_guests','[]'),p_data->>'selection_mode',nullif(p_data->>'template_id','')::uuid,auth.uid())returning id into result;
 else
 update public.whatsapp_campaigns set name=trim(p_data->>'name'),body=p_data->>'body',filters=p_data->'filters',selected_guests=coalesce(p_data->'selected_guests','[]'),selection_mode=p_data->>'selection_mode',template_id=nullif(p_data->>'template_id','')::uuid,version=version+1,updated_at=now()where id=p_id returning id into result;
 end if;
 insert into private.whatsapp_campaign_commands(property_id,request_id,actor_id,payload,result)values(p_property,p_request,auth.uid(),payload,result);
 return result;
end $$;

create function public.launch_whatsapp_campaign(p_property uuid,p_id uuid,p_version int,p_local_time text default null)returns int
language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_campaigns;t public.message_templates;p public.properties;due timestamptz;n int;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 select *into c from public.whatsapp_campaigns where id=p_id and property_id=p_property for update;
 if not found or c.status<>'draft'or c.version is distinct from p_version then raise exception 'Campaign changed. Refresh before scheduling.'using errcode='40001';end if;
 select *into p from public.properties where id=p_property;
 if not exists(select 1 from public.whatsapp_connections where property_id=p_property and status='active')then raise exception 'Connect this hotel’s WhatsApp number before scheduling.'using errcode='22023';end if;
 select *into t from public.message_templates where id=c.template_id and property_id=p_property and category='marketing'and status='approved'and campaign_supported and strpos(body,'{{')=0;
 if not found or t.body<>c.body then raise exception 'Use an approved, variable-free marketing template whose text exactly matches the campaign message.'using errcode='22023';end if;
 due:=now();
 if nullif(p_local_time,'')is not null then
 if p_local_time!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$'then raise exception 'Choose a valid hotel-local schedule.'using errcode='22023';end if;
 due:=p_local_time::timestamp at time zone p.timezone;
 if due<=now()or due>now()+interval '366 days'or to_char(due at time zone p.timezone,'YYYY-MM-DD"T"HH24:MI')<>p_local_time then raise exception 'Schedule a valid future hotel-local time within one year.'using errcode='22023';end if;
 end if;
 insert into public.whatsapp_campaign_recipients(tenant_id,property_id,campaign_id,guest_id,wa_contact_id,guest_name)
 select c.tenant_id,c.property_id,c.id,a.guest_id,a.phone,a.guest_name from private.campaign_audience(c.property_id,c.filters,case when c.selection_mode='selected'then c.selected_guests else null end)a where a.exclusion is null limit 10001;
 get diagnostics n=row_count;
 if n=0 or n>10000 then raise exception 'Choose an eligible audience of 1–10000 distinct phone numbers.'using errcode='22023';end if;
 update public.whatsapp_campaigns set status='scheduled',scheduled_at=due,schedule_timezone=p.timezone,template_name=t.name,template_language=t.language,sender_phone_id=(select phone_number_id from public.whatsapp_connections where property_id=p_property and status='active'),version=version+1,updated_at=now()where id=c.id;
 return n;
end $$;

create function public.cancel_whatsapp_campaign(p_property uuid,p_id uuid,p_version int)returns void
language plpgsql security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 perform 1 from public.whatsapp_campaigns where id=p_id and property_id=p_property and version=p_version and status in('draft','scheduled','running','blocked')for update;
 if not found then raise exception 'Campaign changed or dispatch already finished.'using errcode='40001';end if;
 update public.whatsapp_campaigns set status='cancelled',version=version+1,updated_at=now()where id=p_id;
 update public.whatsapp_campaign_recipients set state='skipped',skip_reason='Campaign cancelled'where campaign_id=p_id and state='pending';
 update public.messages set status='failed',error='Campaign cancelled before dispatch.'where campaign_id=p_id and status='queued';
end $$;

create function public.dispatch_whatsapp_campaigns(p_limit int default 50)returns int
language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_campaigns;conn public.whatsapp_connections;r public.whatsapp_campaign_recipients;conversation uuid;msg uuid;why text;n int:=0;
begin
 -- Completed means dispatch finished, including skipped/failed recipients; delivery/read receipts remain separate.
 update public.whatsapp_campaigns wc set status='completed',updated_at=now()where status='running'and not exists(select 1 from public.whatsapp_campaign_recipients where campaign_id=wc.id and state='pending')and not exists(select 1 from public.messages where campaign_id=wc.id and status in('queued','sending'));
 select *into c from public.whatsapp_campaigns where status in('scheduled','running')and scheduled_at<=now()order by scheduled_at,id limit 1 for update skip locked;
 if not found then return 0;end if;
 select *into conn from public.whatsapp_connections where property_id=c.property_id and status='active'and phone_number_id=c.sender_phone_id;
 if not found or not private.tenant_is_active(c.tenant_id)or not exists(select 1 from public.message_templates where id=c.template_id and property_id=c.property_id and status='approved'and category='marketing'and campaign_supported and name=c.template_name and language=c.template_language and body=c.body and strpos(body,'{{')=0)then
 update public.whatsapp_campaigns set status='blocked',last_error='Connection, account or approved template changed. Cancel and review before creating another campaign.',updated_at=now()where id=c.id;return 0;
 end if;
 update public.whatsapp_campaigns set status='running',updated_at=now()where id=c.id;
 for r in select *from public.whatsapp_campaign_recipients where campaign_id=c.id and state='pending'order by id limit greatest(1,least(p_limit,100))for update skip locked loop
 why:=case when not exists(select 1 from public.guests g where g.id=r.guest_id and private.campaign_phone(g.phone)=r.wa_contact_id)then 'Guest phone changed or guest removed'else private.campaign_contact_error(c.property_id,r.wa_contact_id)end;
 if why is not null then update public.whatsapp_campaign_recipients set state='skipped',skip_reason=why where id=r.id;continue;end if;
 insert into public.conversations(tenant_id,property_id,connection_id,wa_contact_id,contact_name,guest_id)
 values(c.tenant_id,c.property_id,conn.id,r.wa_contact_id,r.guest_name,r.guest_id)
 on conflict(connection_id,wa_contact_id)do update set contact_name=public.conversations.contact_name returning id into conversation;
 insert into public.messages(tenant_id,property_id,conversation_id,direction,type,body,template_id,status,sent_by,creation_request_id,campaign_id)
 values(c.tenant_id,c.property_id,conversation,'out','template',c.body,c.template_id,'queued',c.created_by,r.id,c.id)returning id into msg;
 update public.whatsapp_campaign_recipients set state='queued',message_id=msg where id=r.id;n:=n+1;
 end loop;
 return n;
end $$;
revoke all on function public.campaign_audience(uuid,jsonb,int),public.record_marketing_permission(uuid,uuid,text,text),public.save_whatsapp_campaign(uuid,uuid,uuid,int,jsonb),public.launch_whatsapp_campaign(uuid,uuid,int,text),public.cancel_whatsapp_campaign(uuid,uuid,int),public.dispatch_whatsapp_campaigns(int)from public,anon,authenticated;
grant execute on function public.campaign_audience(uuid,jsonb,int),public.record_marketing_permission(uuid,uuid,text,text),public.save_whatsapp_campaign(uuid,uuid,uuid,int,jsonb),public.launch_whatsapp_campaign(uuid,uuid,int,text),public.cancel_whatsapp_campaign(uuid,uuid,int)to authenticated;
grant execute on function public.dispatch_whatsapp_campaigns(int)to service_role;

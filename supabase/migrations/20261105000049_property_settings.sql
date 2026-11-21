alter table public.properties add column version integer not null default 1;
create table public.property_settings(
 property_id uuid primary key,tenant_id uuid not null,
 check_in_time time not null default '14:00',check_out_time time not null default '11:00',
 arrival_instructions text not null default ''check(length(arrival_instructions)<=2000),stay_information text not null default ''check(length(stay_information)<=2000),
 booking_nights integer not null default 1 check(booking_nights between 1 and 30),booking_adults integer not null default 1 check(booking_adults between 1 and 10),default_rate_plan_id uuid,
 cleaning_target_minutes integer check(cleaning_target_minutes between 1 and 10080),cleaning_priority text not null default 'normal'check(cleaning_priority in('low','normal','high','urgent')),cleaning_checklist jsonb not null default '[]'check(jsonb_typeof(cleaning_checklist)='array'and jsonb_array_length(cleaning_checklist)<=20),
 version integer not null default 1,updated_at timestamptz not null default now(),
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade,
 foreign key(default_rate_plan_id,property_id)references public.rate_plans(id,property_id)on delete set null(default_rate_plan_id)
);
alter table public.property_settings enable row level security;
create policy property_settings_read on public.property_settings for select to authenticated using(private.is_tenant_admin(tenant_id));
insert into public.property_settings(property_id,tenant_id)select id,tenant_id from public.properties;
create function private.initialize_property_settings()returns trigger language plpgsql security definer set search_path=''as $$begin insert into public.property_settings(property_id,tenant_id)values(new.id,new.tenant_id)on conflict do nothing;return new;end $$;
revoke all on function private.initialize_property_settings()from public,anon,authenticated;
create trigger initialize_property_settings after insert on public.properties for each row execute function private.initialize_property_settings();
create function private.property_version()returns trigger language plpgsql set search_path=''as $$begin new.version:=old.version+1;if tg_table_name='property_settings'then new.updated_at:=now();end if;return new;end $$;
revoke all on function private.property_version()from public,anon,authenticated;
create trigger property_version before update on public.properties for each row execute function private.property_version();
create trigger property_settings_version before update on public.property_settings for each row execute function private.property_version();

create table public.property_settings_events(id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,section text not null,actor_id uuid,actor_name text,reason text,details jsonb not null,created_at timestamptz not null default now(),foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade);
create index on public.property_settings_events(property_id,created_at);
alter table public.property_settings_events enable row level security;
create policy property_settings_events_read on public.property_settings_events for select to authenticated using(private.is_tenant_admin(tenant_id));
create table public.property_settings_commands(id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,request_id uuid not null,section text not null,payload jsonb not null,result_id uuid not null,created_at timestamptz not null default now(),unique(property_id,request_id),foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade);
alter table public.property_settings_commands enable row level security;
create policy property_settings_commands_read on public.property_settings_commands for select to authenticated using(private.is_tenant_admin(tenant_id));
create function private.property_settings_audit()returns trigger language plpgsql security definer set search_path=''as $$
declare before_data jsonb;after_data jsonb;prop uuid;actor text;area text;
begin
 before_data:=to_jsonb(old)-'version'-'updated_at'-'creation_request_id';after_data:=to_jsonb(new)-'version'-'updated_at'-'creation_request_id';
 if before_data=after_data then return new;end if;
 if tg_table_name='properties'then prop:=new.id;area:='identity';else prop:=new.property_id;area:='operations';end if;
 select coalesce(full_name,email,'Staff')into actor from public.profiles where id=auth.uid();
 insert into public.property_settings_events(tenant_id,property_id,section,actor_id,actor_name,reason,details)values(new.tenant_id,prop,coalesce(nullif(current_setting('app.property_section',true),''),area),auth.uid(),coalesce(actor,'System'),nullif(current_setting('app.property_reason',true),''),jsonb_build_object('before',before_data,'after',after_data));return new;
end $$;
revoke all on function private.property_settings_audit()from public,anon,authenticated;
create trigger property_settings_audit after update on public.properties for each row execute function private.property_settings_audit();
create trigger property_settings_audit after update on public.property_settings for each row execute function private.property_settings_audit();

create function public.property_settings_save(p_property uuid,p_version integer,p_settings_version integer,p_request uuid,p_section text,p_details jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare p public.properties;s public.property_settings;cmd public.property_settings_commands;next_currency text;next_zone text;rate uuid;target integer;checklist jsonb;label text;
begin
 if not exists(select 1 from public.properties where id=p_property and private.is_tenant_admin(tenant_id))then raise exception 'not permitted'using errcode='42501';end if;
 if p_request is null or p_details is null or jsonb_typeof(p_details)<>'object'or p_section is null or p_section not in('identity','localization','guest','operations')then raise exception 'Reload this settings form.'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('property-settings:'||p_property::text,0));
 select * into cmd from public.property_settings_commands where property_id=p_property and request_id=p_request;
 if found then if cmd.section<>p_section or cmd.payload is distinct from p_details then raise exception 'Request ID already used for different settings.'using errcode='22023';end if;return cmd.result_id;end if;
 select * into p from public.properties where id=p_property for no key update;
 if not private.is_tenant_admin(p.tenant_id)then raise exception 'not permitted'using errcode='42501';end if;
 select * into s from public.property_settings where property_id=p_property for update;
 if p.version is distinct from p_version or s.version is distinct from p_settings_version then raise exception 'These property settings changed. Refresh and review the latest values.'using errcode='40001';end if;
 if length(trim(coalesce(p_details->>'reason','')))not between 3 and 500 then raise exception 'Give a settings-change reason of 3–500 characters.'using errcode='22023';end if;
 perform set_config('app.property_section',p_section,true);perform set_config('app.property_reason',trim(p_details->>'reason'),true);
 if p_section='identity'then
 if length(trim(coalesce(p_details->>'name','')))not between 2 and 120 or coalesce(p_details->>'property_type','')not in('hotel','resort','hostel','homestay')then raise exception 'Enter a property name of 2–120 characters and choose its type.'using errcode='22023';end if;
 if length(coalesce(p_details->>'address',''))>1000 or length(coalesce(p_details->>'city',''))>120 or length(coalesce(p_details->>'contact_phone',''))>40 or length(coalesce(p_details->>'contact_email',''))>254 or coalesce(p_details->>'country_code','')!~'^[A-Z]{2}$'then raise exception 'Check the address, city, country code and contact lengths.'using errcode='22023';end if;
 if coalesce(p_details->>'contact_email','')<>''and p_details->>'contact_email'!~'^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'then raise exception 'Enter a valid contact email.'using errcode='22023';end if;
 update public.properties set name=trim(p_details->>'name'),property_type=p_details->>'property_type',address=coalesce(p_details->>'address',''),city=coalesce(p_details->>'city',''),country_code=p_details->>'country_code',contact_email=lower(coalesce(p_details->>'contact_email','')),contact_phone=coalesce(p_details->>'contact_phone','')where id=p_property;
 elsif p_section='localization'then
 next_currency:=upper(p_details->>'currency');next_zone:=p_details->>'timezone';
 if next_currency is null or next_currency!~'^[A-Z]{3}$'or next_zone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name=next_zone)then raise exception 'Choose a valid currency and IANA timezone.'using errcode='22023';end if;
 if next_zone<>p.timezone and coalesce(p_details->>'confirm_timezone','false')<>'true'then raise exception 'Review and confirm the timezone change.'using errcode='22023';end if;
 if next_currency<>p.currency and coalesce(p_details->>'confirm_currency','false')<>'true'then raise exception 'Review configured prices and confirm the currency change.'using errcode='22023';end if;
 update public.properties set timezone=next_zone,currency=next_currency where id=p_property;
 elsif p_section='guest'then
 if coalesce(p_details->>'check_in_time','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$'or coalesce(p_details->>'check_out_time','')!~'^([01][0-9]|2[0-3]):[0-5][0-9]$'or length(coalesce(p_details->>'arrival_instructions',''))>2000 or length(coalesce(p_details->>'stay_information',''))>2000 then raise exception 'Use valid 24-hour times and guest information up to 2000 characters per field.'using errcode='22023';end if;
 update public.property_settings set check_in_time=(p_details->>'check_in_time')::time,check_out_time=(p_details->>'check_out_time')::time,arrival_instructions=coalesce(p_details->>'arrival_instructions',''),stay_information=coalesce(p_details->>'stay_information','')where property_id=p_property;
 else
 if coalesce(p_details->>'booking_nights','')!~'^[0-9]{1,2}$'or(p_details->>'booking_nights')::integer not between 1 and 30 or coalesce(p_details->>'booking_adults','')!~'^[0-9]{1,2}$'or(p_details->>'booking_adults')::integer not between 1 and 10 then raise exception 'Use default stays of 1–30 nights and 1–10 adults.'using errcode='22023';end if;
 rate:=nullif(p_details->>'default_rate_plan_id','')::uuid;if rate is not null and not exists(select 1 from public.rate_plans where id=rate and property_id=p_property)then raise exception 'Choose a default rate plan from this hotel.'using errcode='22023';end if;
 target:=nullif(p_details->>'cleaning_target_minutes','')::integer;if target is not null and target not between 1 and 10080 then raise exception 'Cleaning targets must be 1–10080 minutes.'using errcode='22023';end if;
 if coalesce(p_details->>'cleaning_priority','')not in('low','normal','high','urgent')then raise exception 'Choose a cleaning priority.'using errcode='22023';end if;
 checklist:=p_details->'cleaning_checklist';if checklist is null or jsonb_typeof(checklist)<>'array'or jsonb_array_length(checklist)>20 then raise exception 'Use up to 20 cleaning checklist items.'using errcode='22023';end if;
 for label in select jsonb_array_elements_text(checklist)loop if length(trim(coalesce(label,'')))not between 1 and 160 then raise exception 'Cleaning steps must be 1–160 characters.'using errcode='22023';end if;end loop;
 update public.property_settings set booking_nights=(p_details->>'booking_nights')::integer,booking_adults=(p_details->>'booking_adults')::integer,default_rate_plan_id=rate,cleaning_target_minutes=target,cleaning_priority=p_details->>'cleaning_priority',cleaning_checklist=checklist where property_id=p_property;
 end if;
 insert into public.property_settings_commands(tenant_id,property_id,request_id,section,payload,result_id)values(p.tenant_id,p_property,p_request,p_section,p_details,p_property);
 perform set_config('app.property_section','',true);perform set_config('app.property_reason','',true);return p_property;
end $$;
revoke all on function public.property_settings_save(uuid,integer,integer,uuid,text,jsonb)from public,anon;
grant execute on function public.property_settings_save(uuid,integer,integer,uuid,text,jsonb)to authenticated;

create function public.property_settings_workspace(p_property uuid,p_page integer default 1)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare p public.properties;s public.property_settings;pg integer:=greatest(1,least(100000,coalesce(p_page,1)));
begin
 select * into p from public.properties where id=p_property;if not found or not private.is_tenant_admin(p.tenant_id)then raise exception 'not permitted'using errcode='42501';end if;
 select * into s from public.property_settings where property_id=p_property;
 return jsonb_build_object('property',to_jsonb(p),'settings',to_jsonb(s)||jsonb_build_object('check_in_time',to_char(s.check_in_time,'HH24:MI'),'check_out_time',to_char(s.check_out_time,'HH24:MI')),'loaded_at',now(),
 'currency_locked',exists(select 1 from public.reservations where property_id=p_property)or exists(select 1 from public.orders where property_id=p_property)or exists(select 1 from public.payments where property_id=p_property),
 'rates',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'adjustment_percent',adjustment_percent)order by name)from public.rate_plans where property_id=p_property),'[]'::jsonb),
 'setup',jsonb_build_object('room_types',(select count(*)from public.accommodation_types where property_id=p_property),'active_rooms',(select count(*)from public.accommodation_units where property_id=p_property and active),'staff',(select count(*)from public.tenant_memberships m where m.tenant_id=p.tenant_id and(m.role in('owner','admin')or exists(select 1 from public.property_memberships where property_id=p_property and user_id=m.user_id))),'services',(select count(*)from public.service_catalog where property_id=p_property and active),'menu_items',(select count(*)from public.menu_items where property_id=p_property and active),'inbox_status',(select status from public.whatsapp_connections where property_id=p_property)),
 'history_page',pg,'history_total',(select count(*)from public.property_settings_events where property_id=p_property),
 'events',coalesce((select jsonb_agg(to_jsonb(x))from(select * from public.property_settings_events where property_id=p_property order by created_at desc,id desc limit 20 offset(pg-1)*20)x),'[]'::jsonb));
end $$;

create function private.property_guest_info(p_property uuid)returns jsonb language sql stable security definer set search_path=''as $$
 select jsonb_build_object('name',p.name,'timezone',p.timezone,'address',p.address,'city',p.city,'country_code',p.country_code,'contact_email',p.contact_email,'contact_phone',p.contact_phone,'check_in_time',to_char(s.check_in_time,'HH24:MI'),'check_out_time',to_char(s.check_out_time,'HH24:MI'),'arrival_instructions',s.arrival_instructions,'stay_information',s.stay_information)
 from public.properties p join public.property_settings s on s.property_id=p.id where p.id=p_property
$$;
revoke all on function private.property_guest_info(uuid)from public,anon,authenticated;
create function public.property_stay_info(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$begin if not private.has_property_access(p_property)then raise exception 'not permitted'using errcode='42501';end if;return private.property_guest_info(p_property);end $$;
create function public.property_booking_defaults(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$begin if not private.has_permission(p_property,'reservations.write')then raise exception 'not permitted'using errcode='42501';end if;return(select jsonb_build_object('nights',booking_nights,'adults',booking_adults,'rate_plan_id',default_rate_plan_id,'check_in_time',to_char(check_in_time,'HH24:MI'),'check_out_time',to_char(check_out_time,'HH24:MI'))from public.property_settings where property_id=p_property);end $$;
revoke all on function public.property_settings_workspace(uuid,integer),public.property_stay_info(uuid),public.property_booking_defaults(uuid)from public,anon;
grant execute on function public.property_settings_workspace(uuid,integer),public.property_stay_info(uuid),public.property_booking_defaults(uuid)to authenticated;

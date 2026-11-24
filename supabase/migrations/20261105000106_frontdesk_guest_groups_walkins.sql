-- Front desk corrections and group actions use the same admission/settlement commands
-- as individual stays. A batch records each result; transport retries cannot repeat it.
alter table public.guests add column profile_version integer not null default 1;
create function private.guest_profile_version()returns trigger language plpgsql set search_path=''as $$
begin new.profile_version:=old.profile_version+1;return new;end $$;
revoke all on function private.guest_profile_version()from public,anon,authenticated,service_role;
create trigger guest_profile_version before update on public.guests for each row execute function private.guest_profile_version();

-- A corrected phone is a new destination, never a transfer of the old permission.
create function private.release_corrected_guest_phone(p_property uuid,p_guest uuid)returns void
language plpgsql security definer set search_path=''as $$
declare phones text[];phone text;
begin
 perform 1 from public.conversations where property_id=p_property and guest_id=p_guest order by id for update;
 perform 1 from public.messages where conversation_id in(select id from public.conversations where property_id=p_property and guest_id=p_guest)order by id for update;
 if exists(select 1 from public.messages where conversation_id in(select id from public.conversations where property_id=p_property and guest_id=p_guest)and direction='out'and(status='sending'or delivery_uncertain))then
  raise exception 'A guest message is sending or its delivery is uncertain. Resolve delivery before changing the phone.'using errcode='22023';
 end if;
 select array_agg(distinct value)into phones from(
  select wa_contact_id as value from public.conversations where property_id=p_property and guest_id=p_guest
  union select wa_contact_id from public.whatsapp_guest_authorizations where property_id=p_property and guest_id=p_guest
  union select bc.phone from private.whatsapp_booking_contacts bc where property_id=p_property and guest_id=p_guest
 )x;
 foreach phone in array coalesce(phones,'{}'::text[])loop perform private.revoke_whatsapp_consent(p_property,phone,'both','staff_phone_correction');end loop;
 update public.messages set guest_identity_reset_at=clock_timestamp(),status=case when status='queued'then'failed'else status end,error=case when status='queued'then'Guest phone corrected; old permission removed.'else error end
 where direction='out'and conversation_id in(select id from public.conversations where property_id=p_property and guest_id=p_guest)and guest_identity_reset_at is null;
 update public.whatsapp_automation_events set state='skipped',reason='Guest phone corrected.'where property_id=p_property and guest_id=p_guest and state in('pending','blocked','queued');
 update public.whatsapp_campaign_recipients set state='skipped',skip_reason='Guest phone corrected.'where property_id=p_property and(guest_id=p_guest or wa_contact_id=any(coalesce(phones,'{}'::text[])))and state in('pending','queued');
 update public.guest_access_tokens set revoked_at=clock_timestamp()where property_id=p_property and revoked_at is null and reservation_id in(select id from public.reservations where property_id=p_property and guest_id=p_guest);
 update private.whatsapp_journey_actions set expires_at=clock_timestamp()where conversation_id in(select id from public.conversations where property_id=p_property and guest_id=p_guest)and consumed_at is null;
 update private.whatsapp_guest_inbound_jobs set state='done'where message_id in(select m.id from public.messages m join public.conversations c on c.id=m.conversation_id where c.property_id=p_property and c.guest_id=p_guest)and state='pending';
 update private.whatsapp_consent_challenges set cancelled_at=clock_timestamp()where property_id=p_property and guest_id=p_guest and consumed_at is null and cancelled_at is null;
 delete from private.whatsapp_booking_contacts where property_id=p_property and guest_id=p_guest;
 delete from public.whatsapp_guest_authorizations where property_id=p_property and guest_id=p_guest;
 update public.conversations set guest_id=null,contact_name=null,last_inbound_at=null,version=version+1 where property_id=p_property and guest_id=p_guest;
end $$;
revoke all on function private.release_corrected_guest_phone(uuid,uuid)from public,anon,authenticated,service_role;

create function public.frontdesk_edit_guest(p_property uuid,p_guest uuid,p_version integer,p_name text,p_phone text,p_email text,p_reason text,p_confirm_phone boolean default false)returns void
language plpgsql security definer set search_path=''as $$
declare g public.guests;tenant uuid;hotel uuid;hotels uuid[];v_phone text:=nullif(trim(p_phone),'');v_email text:=nullif(trim(p_email),'');changed_phone boolean;
begin
 perform private.staff_share(p_property);
 if not private.has_permission(p_property,'reservations.write')then raise exception 'Guest editing requires reservation write access.'using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property;
 select *into g from public.guests where id=p_guest and tenant_id=tenant;
 if g.id is null or not(exists(select 1 from public.reservations where guest_id=g.id and property_id=p_property)or exists(select 1 from public.conversations where guest_id=g.id and property_id=p_property)or private.is_tenant_admin(tenant)and private.guest_profile_unused(g.id))then raise exception 'Guest not found in this hotel.'using errcode='42501';end if;
 select array_agg(distinct property_id order by property_id)into hotels from(
  select property_id from public.reservations where guest_id=g.id
  union select property_id from public.conversations where guest_id=g.id
  union select property_id from public.whatsapp_guest_authorizations where guest_id=g.id
  union select p_property
 )x;
 foreach hotel in array hotels loop
  if not private.has_permission(hotel,'reservations.write')then raise exception 'This profile is shared with another hotel. An administrator with access to all its hotels must edit it.'using errcode='42501';end if;
  perform 1 from public.properties where id=hotel for update;
 end loop;
 select *into g from public.guests where id=p_guest for update;
 if g.profile_version is distinct from p_version then raise exception 'Guest details changed. Refresh before saving.'using errcode='40001';end if;
 if length(trim(coalesce(p_name,'')))not between 2 and 120 or length(coalesce(v_phone,''))>40 or length(coalesce(v_email,''))>254 or(v_email is not null and v_email!~'^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')or length(trim(coalesce(p_reason,'')))not between 3 and 500 then raise exception 'Check the name, contact details and change reason.'using errcode='22023';end if;
 changed_phone:=v_phone is distinct from g.phone;
 if changed_phone and not coalesce(p_confirm_phone,false)then raise exception 'Confirm the phone correction and removal of old WhatsApp permission.'using errcode='22023';end if;
 if changed_phone then
  foreach hotel in array hotels loop
   if exists(select 1 from public.conversations where property_id=hotel and wa_contact_id=private.campaign_phone(v_phone)and guest_id is not null and guest_id<>g.id)or exists(select 1 from public.whatsapp_guest_authorizations where property_id=hotel and wa_contact_id=private.campaign_phone(v_phone)and guest_id<>g.id)then raise exception 'That phone is linked to another guest. Review the existing profile first.'using errcode='22023';end if;
   perform private.release_corrected_guest_phone(hotel,g.id);
  end loop;
 end if;
 update public.guests set full_name=trim(p_name),phone=v_phone,email=v_email where id=g.id;
 insert into private.guest_identity_audit(property_id,guest_id,actor_id,action,reason,details)values(p_property,g.id,auth.uid(),'guest_details_updated',trim(p_reason),jsonb_build_object('previous',jsonb_build_object('name',g.full_name,'phone',g.phone,'email',g.email),'current',jsonb_build_object('name',trim(p_name),'phone',v_phone,'email',v_email),'phone_permission_reset',changed_phone,'hotels',hotels));
 insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,actor_id,details)
 select tenant_id,property_id,id,'guest_details_updated',auth.uid(),jsonb_build_object('reason',trim(p_reason),'phone_permission_reset',changed_phone)from public.reservations where guest_id=g.id;
end $$;
revoke all on function public.frontdesk_edit_guest(uuid,uuid,integer,text,text,text,text,boolean)from public,anon;
grant execute on function public.frontdesk_edit_guest(uuid,uuid,integer,text,text,text,text,boolean)to authenticated;

alter function public.guest_identity_workspace(uuid,text,integer)rename to guest_identity_workspace_before_edit;
revoke all on function public.guest_identity_workspace_before_edit(uuid,text,integer)from public,anon,authenticated,service_role;
create function public.guest_identity_workspace(p_property uuid,p_query text default '',p_page integer default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare result jsonb;
begin
 result:=public.guest_identity_workspace_before_edit(p_property,p_query,p_page);
 return jsonb_set(result,'{rows}',coalesce((select jsonb_agg(x.value||jsonb_build_object('profile_version',g.profile_version)order by x.ord)from jsonb_array_elements(result->'rows')with ordinality x(value,ord)join public.guests g on g.id=(x.value->>'id')::uuid),'[]'::jsonb));
end $$;
revoke all on function public.guest_identity_workspace(uuid,text,integer)from public,anon;
grant execute on function public.guest_identity_workspace(uuid,text,integer)to authenticated;

create table private.frontdesk_batches(property_id uuid not null references public.properties(id),request_id uuid not null,actor_id uuid not null,action text not null,items jsonb not null,result jsonb not null,created_at timestamptz not null default now(),primary key(property_id,request_id));
revoke all on private.frontdesk_batches from public,anon,authenticated,service_role;
create function public.frontdesk_bulk_action(p_property uuid,p_request uuid,p_action text,p_items jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$
declare prior private.frontdesk_batches;item jsonb;rid uuid;v integer;results jsonb:='[]';why text;code text;
begin
 perform private.staff_share(p_property);
 if not private.has_permission(p_property,'frontdesk.manage')or not private.has_permission(p_property,'reservations.read')then raise exception 'Front desk access is required.'using errcode='42501';end if;
 if p_request is null or p_action is null or p_action not in('check_in','check_out')or jsonb_typeof(p_items)is distinct from'array'or jsonb_array_length(p_items)not between 1 and 100 then raise exception 'Select 1–100 stays and a check-in or checkout action.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('frontdesk-batch:'||p_property::text||p_request::text,0));
 select *into prior from private.frontdesk_batches where property_id=p_property and request_id=p_request;
 if found then
  if prior.actor_id<>auth.uid()or prior.action<>p_action or prior.items is distinct from p_items then raise exception 'Batch request already used. Refresh before starting another batch.'using errcode='40001';end if;
  return prior.result;
 end if;
 if exists(select 1 from jsonb_array_elements(p_items)x where jsonb_typeof(x)is distinct from'object'or coalesce(x->>'id','')!~*'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'or coalesce(x->>'version','')!~'^[0-9]{1,9}$')then raise exception 'Reload the selected stays.'using errcode='22023';end if;
 if(select count(distinct x->>'id')from jsonb_array_elements(p_items)x)<>jsonb_array_length(p_items)then raise exception 'Select each stay only once.'using errcode='22023';end if;
 if exists(select 1 from jsonb_array_elements(p_items)x where not exists(select 1 from public.reservations r where r.id=(x->>'id')::uuid and r.property_id=p_property))then raise exception 'Every selected stay must belong to this hotel.'using errcode='42501';end if;
 -- Canonical ordering avoids two overlapping batches taking reservation locks in reverse order.
 for item in select value from jsonb_array_elements(p_items)order by value->>'id'loop
  rid:=(item->>'id')::uuid;v:=(item->>'version')::integer;
  begin
   perform public.frontdesk_action(rid,v,p_action);
   results:=results||jsonb_build_array(jsonb_build_object('id',rid,'success',true));
  exception when others then
   get stacked diagnostics why=message_text,code=returned_sqlstate;
   if code not in('22023','40001','42501','23P01','P0002')then raise;end if;
   results:=results||jsonb_build_array(jsonb_build_object('id',rid,'success',false,'error',case when code='42501'then 'Your access changed. Ask your administrator.'else why end));
  end;
 end loop;
 insert into private.frontdesk_batches(property_id,request_id,actor_id,action,items,result)values(p_property,p_request,auth.uid(),p_action,p_items,results);
 return results;
end $$;
revoke all on function public.frontdesk_bulk_action(uuid,uuid,text,jsonb)from public,anon;
grant execute on function public.frontdesk_bulk_action(uuid,uuid,text,jsonb)to authenticated;

-- Creates a walk-in and attempts admission in one command. If documents or room
-- readiness block admission, retain one confirmed stay for staff to resolve.
create function public.frontdesk_walk_in(p_property uuid,p_currency text,p_request uuid,p_guest uuid,p_guest_name text,p_phone text,p_email text,p_type uuid,p_in date,p_out date,p_adults integer,p_children integer,p_rate uuid default null,p_unit uuid default null,p_notes text default '',p_quote numeric default null,p_contact_permission boolean default false,p_contact_evidence text default '')returns jsonb
language plpgsql security definer set search_path=''as $$
declare rid uuid;v integer;state text;d date;why text;unit uuid:=p_unit;candidate jsonb;
begin
 perform private.staff_share(p_property);
 if not private.has_permission(p_property,'reservations.write')or not private.has_permission(p_property,'frontdesk.manage')then raise exception 'Booking and front desk access are required for a walk-in.'using errcode='42501';end if;
 if p_request is null then raise exception 'Reload the walk-in form.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_property::text||p_request::text,0));
 select(now()at time zone timezone)::date into d from public.properties where id=p_property;
 select id,status into rid,state from public.reservations where property_id=p_property and creation_request_id=p_request;
 if rid is not null and not exists(select 1 from public.reservations where id=rid and source='walk_in'and(p_guest is null or guest_id=p_guest))then raise exception 'This request belongs to another booking. Reload the walk-in form.'using errcode='40001';end if;
 if rid is not null then return jsonb_build_object('id',rid,'status',state,'admission_error',case when state='confirmed'then 'This walk-in was already saved. Open the stay to finish its admission checks.'end);end if;
 if p_in is distinct from d then raise exception 'Walk-in check-in must start today in hotel time.'using errcode='22023';end if;
 if unit is null then
  select x into candidate from jsonb_array_elements(public.frontdesk_quote(p_property,p_type,p_in,p_out,p_adults,p_children,p_rate)->'rooms')x
   where x->>'housekeeping_status'='clean'and not exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id where h.unit_id=(x->>'id')::uuid and h.active and r.status='checked_in')limit 1;
  unit:=(candidate->>'id')::uuid;
 end if;
 if p_guest is null then rid:=public.frontdesk_create_whatsapp(p_property,p_currency,p_request,p_guest_name,p_phone,p_email,p_type,p_in,p_out,p_adults,p_children,p_rate,unit,p_notes,'walk_in',p_quote,p_contact_permission,p_contact_evidence);
 else rid:=public.frontdesk_create_existing_guest(p_property,p_currency,p_request,p_guest,p_type,p_in,p_out,p_adults,p_children,p_rate,unit,p_notes,'walk_in',p_quote,p_contact_permission,p_contact_evidence);end if;
 select version into v from public.reservations where id=rid;
 begin perform public.frontdesk_action(rid,v,'check_in');
 exception when sqlstate '22023'then get stacked diagnostics why=message_text;
 end;
 return jsonb_build_object('id',rid,'status',(select status from public.reservations where id=rid),'admission_error',why);
end $$;
revoke all on function public.frontdesk_walk_in(uuid,text,uuid,uuid,text,text,text,uuid,date,date,integer,integer,uuid,uuid,text,numeric,boolean,text)from public,anon;
grant execute on function public.frontdesk_walk_in(uuid,text,uuid,uuid,text,text,text,uuid,date,date,integer,integer,uuid,uuid,text,numeric,boolean,text)to authenticated;

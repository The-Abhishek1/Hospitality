-- A room-cleaning task always snapshots the hotel's saved checklist, including
-- tasks started from the general task form. Existing work is never rewritten.
do $$declare d text;begin
 d:=pg_get_functiondef('public.task_create_advanced(uuid,uuid,jsonb)'::regprocedure);
 d:=replace(d,'labels:=coalesce(p_details->''checklist'',''[]'');',E'labels:=coalesce(p_details->''checklist'',''[]'');\n if p_details->>''kind''=''housekeeping''and room is not null and exists(select 1 from public.property_settings where property_id=p_property and jsonb_array_length(cleaning_checklist)>0)then select cleaning_checklist into labels from public.property_settings where property_id=p_property;end if;');execute d;
 -- Provisional WhatsApp bookings appear in the staff's active reservation list.
 d:=pg_get_functiondef('public.reservation_workspace(uuid,jsonb)'::regprocedure);d:=replace(d,'when ''upcoming'' then r.status in (''confirmed'',''checked_in'')','when ''upcoming'' then r.status in (''pending_payment'',''confirmed'',''checked_in'')');execute d;
end $$;
-- A provisional or expired unpaid booking is still an enquiry. The inbox and
-- inbound router share this predicate, so paid confirmation moves both together.
create or replace function private.whatsapp_enquiry(p_conversation uuid)returns boolean language sql stable security definer set search_path=''as $$
 select not exists(select 1 from public.conversations c join public.reservations r on r.guest_id=c.guest_id and r.property_id=c.property_id where c.id=p_conversation and r.status<>'pending_payment'and(r.booking_origin is distinct from 'whatsapp'or r.status<>'cancelled'or exists(select 1 from public.hotel_payment_requests j where j.reservation_id=r.id and j.state='paid')))
$$;
-- Guest-request cleaning is an in-stay service; snapshot its checklist without
-- turning it into a turnover task or changing the occupied room's readiness.
create function private.guest_cleaning_checklist()returns trigger language plpgsql security definer set search_path=''as $$begin
 if new.guest_request_id is not null and new.kind='housekeeping'and new.title ilike '%clean%'then
  insert into public.task_checklists(tenant_id,property_id,task_id,label,position)
  select new.tenant_id,new.property_id,new.id,value,ordinality-1 from public.property_settings s cross join lateral jsonb_array_elements_text(s.cleaning_checklist)with ordinality where s.property_id=new.property_id;
 end if;return new;
end $$;
create trigger guest_cleaning_checklist after insert on public.tasks for each row execute function private.guest_cleaning_checklist();
revoke all on function private.guest_cleaning_checklist()from public,anon,authenticated,service_role;
do $$declare d text;begin
 d:=pg_get_functiondef('public.whatsapp_booking_workspace(uuid)'::regprocedure);
 d:=replace(d,'return coalesce(',E'return jsonb_build_object(''payment_ready'',exists(select 1 from public.hotel_payment_connections c join private.hotel_payment_credentials k on k.connection_id=c.id where c.property_id=p_property and c.status=''active''and c.checkout_enabled and exists(select 1 from private.payment_worker_configuration where enabled)))||coalesce(');execute d;
end $$;
do $$declare f record;d text;begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private'and p.proname in('queue_whatsapp_guest_reply_before_journey','queue_whatsapp_guest_reply_flat')loop
  d:=pg_get_functiondef(f.oid);d:=replace(d,'''check_in'',r.check_in::text,''check_out'',r.check_out::text','''check_in'',to_char(r.check_in,''DD-MM-YYYY''),''check_out'',to_char(r.check_out,''DD-MM-YYYY'')');execute d;
 end loop;
end $$;
-- Date rendering must never rewrite a date embedded in a working URL.
create or replace function private.whatsapp_display_text(p_text text)returns text language plpgsql immutable set search_path=''as $$
declare remaining text:=p_text;result text:='';link text[];part text;pos integer;begin
 if p_text is null then return null;end if;
 loop
  link:=regexp_match(remaining,'https?://[^[:space:]]+');
  if link is null then part:=remaining;else pos:=strpos(remaining,link[1]);part:=left(remaining,pos-1);end if;
  result:=result||regexp_replace(regexp_replace(regexp_replace(part,'\mArrival\M','Check-in','g'),'\mDeparture\M','Check-out','g'),'\m([0-9]{4})-([0-9]{2})-([0-9]{2})\M','\3-\2-\1','g');
  if link is null then return result;end if;
  result:=result||link[1];remaining:=substring(remaining from pos+length(link[1]));
 end loop;
end $$;
-- Overlapping leave must be resolved deliberately, instead of creating two deductions.
do $$declare d text;begin
 d:=pg_get_functiondef('public.staff_manage(uuid,uuid,text,jsonb)'::regprocedure);
 d:=replace(d,'insert into public.staff_leave_requests(staff_id,property_id,start_day,end_day,paid,reason,actor)',E'if exists(select 1 from public.staff_leave_requests where staff_id=emp.id and status in(''pending'',''approved'')and daterange(start_day,end_day+1,''[)'')&&daterange(target_day,finish+1,''[)''))then raise exception ''This employee already has leave in that period.''using errcode=''22023'';end if;\n insert into public.staff_leave_requests(staff_id,property_id,start_day,end_day,paid,reason,actor)');execute d;
end $$;
-- Historical welcome keys from older releases still count as the one welcome.
do $$declare d text;begin
 d:=pg_get_functiondef('private.capture_whatsapp_event(uuid,uuid,text,text,text,uuid,text,jsonb,timestamptz,timestamptz)'::regprocedure);
 d:=replace(d,'if p_event=''booking_confirmed''then p_dedup:=',E'if p_event=''booking_confirmed''and exists(select 1 from public.whatsapp_automation_events where property_id=p_property and reservation_id=r.id and event_key=p_event)then return;end if;\n if p_event=''documents_received''and exists(select 1 from public.whatsapp_automation_events where property_id=p_property and reservation_id=r.id and event_key=p_event and source_id=p_source)then return;end if;\n if p_event=''booking_confirmed''then p_dedup:=');execute d;
 d:=pg_get_functiondef('public.payment_workspace(uuid,uuid)'::regprocedure);d:=replace(d,'select id,reservation_id,connection_id,amount','select (select mode from public.hotel_payment_connections hc where hc.id=hotel_payment_requests.connection_id)as mode,purpose,id,reservation_id,connection_id,amount');execute d;
 d:=pg_get_functiondef('private.confirm_enquiry_booking(uuid,uuid)'::regprocedure);d:=replace(d,'if price is distinct from s.quote',E'if price<2 then raise exception ''Online deposits require a room total of at least INR 2.00. Reception can help.''using errcode=''22023'';end if;\n if price is distinct from s.quote');execute d;
end $$;
-- Provider processing problems and signed payment failures are visible milestones,
-- not a reason to create another payment link or silently confirm a booking.
create function private.booking_payment_problem_trigger()returns trigger language plpgsql security definer set search_path=''as $$begin
 if new.purpose='booking_deposit'and new.state in('unknown','failed')and new.attempts>=2 and new.last_error is not null and new.last_error is distinct from old.last_error then
  perform private.capture_whatsapp_event(new.property_id,new.reservation_id,'booking_payment_failed','deposit-problem:'||new.id,'hotel_payment_requests',new.id,null,jsonb_build_object('amount',new.amount::numeric/100));perform private.wake_whatsapp_guest_worker();
 end if;return new;
end $$;
create trigger booking_payment_problem after update of last_error,state on public.hotel_payment_requests for each row execute function private.booking_payment_problem_trigger();
revoke all on function private.booking_payment_problem_trigger()from public,anon,authenticated,service_role;
create function public.record_booking_payment_problem(p_connection uuid,p_event text,p_order text,p_link text,p_payment text)returns boolean language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;begin
 if not exists(select 1 from private.hotel_payment_webhooks where connection_id=p_connection and event_id=p_event)then return false;end if;
 select *into job from public.hotel_payment_requests where connection_id=p_connection and purpose='booking_deposit'and state in('pending','creating','unknown','ready')and(provider_order_id=p_order or provider_link_id=p_link or provider_payment_id=p_payment)limit 1;
 if job.id is null then return false;end if;
 perform private.capture_whatsapp_event(job.property_id,job.reservation_id,'booking_payment_failed','deposit-problem:'||job.id,'hotel_payment_requests',job.id,null,jsonb_build_object('amount',job.amount::numeric/100));perform private.wake_whatsapp_guest_worker();return true;
end $$;
revoke all on function public.record_booking_payment_problem(uuid,text,text,text,text)from public,anon,authenticated;grant execute on function public.record_booking_payment_problem(uuid,text,text,text,text)to service_role;
do $$declare d text;begin
 d:=pg_get_functiondef('private.whatsapp_native_event_error(uuid)'::regprocedure);d:=replace(d,'if e.source_table=''orders''then',E'if e.event_key in(''booking_deposit_requested'',''booking_payment_failed'')and exists(select 1 from public.hotel_payment_requests where id=e.source_id and state in(''paid'',''expired'',''cancelled''))then return ''Source status changed.'';end if;\n if e.source_table=''orders''then');execute d;
 d:=pg_get_functiondef('private.whatsapp_automation_error_before_defaults(uuid)'::regprocedure);d:=replace(d,'if e.event_key in(''booking_confirmed''',E'if e.event_key in(''booking_deposit_requested'',''booking_payment_failed'')and exists(select 1 from public.hotel_payment_requests where id=e.source_id and state in(''paid'',''expired'',''cancelled''))then return ''Source status changed.'';end if;\n if e.event_key in(''booking_confirmed''');execute d;
end $$;

alter table public.orders drop constraint orders_status_check;
alter table public.orders add constraint orders_status_check check(status in('placed','preparing','ready','serving','served','cancelled'));
alter table public.orders add column serving_at timestamptz;
do $$declare f record;d text;begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','private')and p.prosrc like '%''placed'',''preparing'',''ready''%'loop
  d:=pg_get_functiondef(f.oid);d:=replace(d,'''placed'',''preparing'',''ready''','''placed'',''preparing'',''ready'',''serving''');execute d;
 end loop;
 d:=pg_get_functiondef('public.set_order_status(uuid,text)'::regprocedure);d:=replace(d,'(''ready'',''served'')','(''ready'',''served''),(''ready'',''serving''),(''serving'',''served'')');execute d;
 d:=pg_get_functiondef('private.whatsapp_domain_event()'::regprocedure);d:=replace(d,'when''ready''then''order_ready''','when''ready''then''order_ready''when''serving''then''order_serving''');
 d:=replace(d,'ev:=''payment_received'';','ev:=case when exists(select 1 from public.hotel_payment_requests where id=(d->>''online_request_id'')::uuid and purpose=''booking_deposit'')then null else''payment_received''end;');execute d;
end $$;
create function private.order_serving_time()returns trigger language plpgsql set search_path=''as $$begin if new.status='serving'and old.status<>'serving'then new.serving_at:=now();end if;return new;end $$;
create trigger order_serving_time before update on public.orders for each row execute function private.order_serving_time();
revoke all on function private.order_serving_time()from public,anon,authenticated,service_role;

-- Common requests work even before a hotel configures its service catalog.
-- Each request is confirmed by the guest, deduplicated while open, and linked to work.
do $$declare d text;begin
 d:=pg_get_functiondef('private.handle_whatsapp_journey_before_poststay(uuid,uuid,text,text)'::regprocedure);
 d:=replace(d,'if total=0 then body:=''Tell reception what you need and a team member will help.'';buttons:=jsonb_build_array(private.journey_button(c.id,r.id,''reception'',''Talk to reception''));',E'if total=0 then\n body:=''Choose a service. We will ask you to confirm before creating the request.'';\n rows:=jsonb_build_array(private.journey_button(c.id,r.id,''quick_service_prompt'',''Fresh towels'',jsonb_build_object(''service'',''Fresh towels'',''kind'',''housekeeping'')),private.journey_button(c.id,r.id,''quick_service_prompt'',''Room cleaning'',jsonb_build_object(''service'',''Room cleaning'',''kind'',''housekeeping'')),private.journey_button(c.id,r.id,''quick_service_prompt'',''Repair / maintenance'',jsonb_build_object(''service'',''Repair / maintenance'',''kind'',''maintenance'')),private.journey_button(c.id,r.id,''quick_service_prompt'',''Other assistance'',jsonb_build_object(''service'',''Other assistance'',''kind'',''general'')),private.journey_button(c.id,r.id,''menu'',''Main menu''));');
 d:=replace(d,'elsif action in(''service_prompt'',''service_confirm'')then',E'elsif action in(''quick_service_prompt'',''quick_service_confirm'')then\n if r.status<>''checked_in''then body:=''Room services open after check-in. Reception can help with earlier requests.'';\n elsif a.details->>''service''not in(''Fresh towels'',''Room cleaning'',''Repair / maintenance'',''Other assistance'')or a.details->>''kind''not in(''housekeeping'',''maintenance'',''general'')then raise exception ''Choose a service again.''using errcode=''22023'';\n elsif action=''quick_service_prompt''then body:=''Request ''||(a.details->>''service'')||'' for your room? The hotel team will receive this request.'';buttons:=jsonb_build_array(private.journey_button(c.id,r.id,''quick_service_confirm'',''Send request'',a.details),private.journey_button(c.id,r.id,''services'',''Go back''));\n else\n select id into target from public.guest_requests where reservation_id=r.id and title=a.details->>''service''and status in(''new'',''in_progress'')order by created_at desc limit 1;\n if target is null then target:=private.create_guest_request_core(p.id,r.id,null,a.details->>''service'',''Guest confirmed in WhatsApp.'',''whatsapp'',null);end if;\n if not exists(select 1 from public.tasks where guest_request_id=target)then insert into public.tasks(tenant_id,property_id,title,description,kind,priority,reservation_id,guest_request_id)values(r.tenant_id,p.id,a.details->>''service'',''Guest request via WhatsApp. Check Guest requests for details.'',a.details->>''kind'',''normal'',r.id,target);end if;\n update private.whatsapp_journey_actions set result_id=target where id=a.id;body:=''Your request for ''||(a.details->>''service'')||'' has been created. Reference: ''||upper(left(target::text,8))||''. Our team will update you here when stay updates are enabled.'';\n end if;\n elsif action in(''service_prompt'',''service_confirm'')then');
 -- A configured catalog without routing still creates actionable work.
 d:=replace(d,'update private.whatsapp_journey_actions set result_id=target where id=a.id;',E'if target is not null and not exists(select 1 from public.tasks where guest_request_id=target)then insert into public.tasks(tenant_id,property_id,title,description,kind,priority,reservation_id,guest_request_id)select r.tenant_id,p.id,gr.title,gr.notes,''general'',gr.priority,r.id,target from public.guest_requests gr where gr.id=target;end if;\n update private.whatsapp_journey_actions set result_id=target where id=a.id;');execute d;
end $$;

-- Booking receipts/expiry are transactional and use the original booking contact,
-- without silently opting the guest into ongoing updates or marketing.
do $$declare d text;begin
 d:=pg_get_functiondef('private.whatsapp_automation_error_before_defaults(uuid)'::regprocedure);d:=replace(d,'e.event_key=''booking_confirmed''','e.event_key in(''booking_confirmed'',''booking_deposit_paid'',''booking_deposit_requested'',''booking_payment_expired'',''booking_payment_failed'')');execute d;
 d:=pg_get_functiondef('public.dispatch_whatsapp_automations_provider(integer,text)'::regprocedure);d:=replace(d,'e.event_key=''booking_confirmed''','e.event_key in(''booking_confirmed'',''booking_deposit_paid'',''booking_deposit_requested'',''booking_payment_expired'',''booking_payment_failed'')');execute d;
 d:=pg_get_functiondef('private.whatsapp_automation_error_before_journey(uuid)'::regprocedure);d:=replace(d,'''booking_cancelled'',''payment_received''','''booking_cancelled'',''booking_payment_expired'',''booking_payment_failed'',''payment_received''');execute d;
end $$;
-- Native payment receipts and expiry notices use the booking's contact proof.
do $$declare d text;begin
 d:=pg_get_functiondef('private.whatsapp_native_event_error(uuid)'::regprocedure);
 d:=replace(d,'''booking_confirmed'',''documents_received''','''booking_confirmed'',''booking_deposit_paid'',''booking_payment_expired'',''booking_payment_failed'',''documents_received''');
 d:=replace(d,'r.status in(''cancelled'',''no_show'',''checked_out'')','r.status in(''cancelled'',''no_show'',''checked_out'')and e.event_key not in(''booking_payment_expired'',''booking_payment_failed'')');execute d;
 d:=pg_get_functiondef('private.whatsapp_native_event_body(uuid,text)'::regprocedure);
 d:=replace(d,'when''documents_received''then',E'when''booking_deposit_paid''then p.name||'' received your 50% booking deposit of ''||(e.payload->>''amount'')||'' ''||trim(r.currency)||''. Reference: ''||ref||''. Your booking confirmation follows separately.''\n when''booking_payment_expired''then ''Your 15-minute payment hold at ''||p.name||'' has expired. Booking ''||ref||'' is not confirmed and the room has been released. Send BOOK to check availability. If you already paid, contact reception before paying again.''\n when''booking_payment_failed''then ''Payment for booking ''||ref||'' could not be verified. Contact reception; do not create multiple payments.''\n when''documents_received''then');execute d;
 d:=pg_get_functiondef('public.dispatch_whatsapp_automations(integer,text)'::regprocedure);
 d:=replace(d,'null,e.reservation_id);','null,null);');execute d;
end $$;
-- Match receipt wording to the merchant's mode; live guests must never see test instructions.
do $$declare d text;begin
 d:=pg_get_functiondef('private.request_online_payment(uuid,uuid,uuid,uuid)'::regprocedure);d:=replace(d,'or not(select payment_test_mode from public.properties where id=r.property_id)','or c.mode=''test''and not(select payment_test_mode from public.properties where id=r.property_id)');d:=replace(d,'Enable this hotel’s Razorpay Test Mode account for INR checkout payments.','Enable this hotel’s Razorpay account for INR payments.');execute d;
 d:=pg_get_functiondef('private.payment_guest_notice_checkout(uuid,boolean)'::regprocedure);
 d:=replace(d,'buttons jsonb;','buttons jsonb;v_mode text;');d:=replace(d,'balance:=private.reservation_balance',E'select mode into v_mode from public.hotel_payment_connections where id=job.connection_id;\n balance:=private.reservation_balance');
 d:=replace(d,'''Test payment received: ''','case when v_mode=''test''then''Test payment received: ''else''Payment received: ''end');
 d:=replace(d,''' INR. No real money was collected.''',''' INR.''||case when v_mode=''test''then'' No real money was collected.''else''''end');
 d:=replace(d,''' INR. This is a Razorpay Test Mode link; use test payment details only. After payment, return here to confirm checkout.''',''' INR.''||case when v_mode=''test''then'' This is a Test Mode link; use test details only.''else''''end||'' After payment, return here to confirm checkout.''');
 d:=replace(d,'''Pay securely · test''','case when v_mode=''test''then''Pay securely · test''else''Pay securely''end');execute d;
 d:=pg_get_functiondef('private.handle_whatsapp_journey_before_poststay(uuid,uuid,text,text)'::regprocedure);d:=replace(d,'''Preparing your secure Razorpay Test Mode payment link. No real money will be collected. Your bill must be settled before checkout.''','''Preparing your secure payment link. Your bill must be settled before checkout.''');execute d;
end $$;

-- One captured group deposit, allocated as real receipts on each room's folio.
alter table public.hotel_payment_requests add column booking_group_id uuid references public.reservation_groups(id)on delete set null,add column booking_confirmed_at timestamptz;
create table public.hotel_payment_allocations(
 request_id uuid not null references public.hotel_payment_requests(id)on delete cascade,reservation_id uuid not null references public.reservations(id)on delete cascade,
 tenant_id uuid not null,property_id uuid not null,folio_id uuid not null,amount bigint not null check(amount>0),position integer not null,
 primary key(request_id,reservation_id),unique(request_id,folio_id),foreign key(property_id,tenant_id)references public.properties(id,tenant_id)on delete cascade,
 foreign key(reservation_id,property_id)references public.reservations(id,property_id),foreign key(folio_id,property_id)references public.folios(id,property_id)
);
alter table public.hotel_payment_allocations enable row level security;
revoke all on public.hotel_payment_allocations from public,anon,authenticated;
grant select on public.hotel_payment_allocations to authenticated;grant all on public.hotel_payment_allocations to service_role;
create policy payment_allocations_read on public.hotel_payment_allocations for select to authenticated using(private.has_permission(property_id,'billing.manage')or private.has_permission(property_id,'finance.read'));
-- Provider IDs describe the gateway transaction; one group transaction has several folio entries.
alter table public.payments drop constraint payments_provider_payment_id_key;
create unique index payments_provider_folio on public.payments(provider_payment_id,coalesce(folio_id,order_id))where provider_payment_id is not null;
alter table public.refunds drop constraint refunds_provider_refund_id_key;
create unique index refunds_provider_payment on public.refunds(provider_refund_id,payment_id)where provider_refund_id is not null;
create function private.gateway_ledger_writer()returns trigger language plpgsql set search_path=''as $$begin
 if current_user in('anon','authenticated','service_role')and(new.provider_payment_id is not null)then raise exception 'Gateway receipts must be recorded by verified payment reconciliation.'using errcode='42501';end if;return new;
end $$;
create function private.gateway_refund_writer()returns trigger language plpgsql set search_path=''as $$begin
 if current_user in('anon','authenticated','service_role')and new.provider_refund_id is not null then raise exception 'Gateway refunds must be recorded by verified payment reconciliation.'using errcode='42501';end if;return new;
end $$;
create trigger gateway_ledger_writer before insert on public.payments for each row execute function private.gateway_ledger_writer();
create trigger gateway_refund_writer before insert on public.refunds for each row execute function private.gateway_refund_writer();
revoke all on function private.gateway_ledger_writer(),private.gateway_refund_writer()from public,anon,authenticated,service_role;

alter function private.confirm_enquiry_booking(uuid,uuid)rename to confirm_enquiry_booking_single;
revoke all on function private.confirm_enquiry_booking_single(uuid,uuid)from public,anon,authenticated,service_role;
create function private.confirm_enquiry_booking(p_conversation uuid,p_source uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare s private.whatsapp_booking_sessions;c public.conversations;p public.properties;merchant public.hotel_payment_connections;gid uuid;rid uuid;lead_id uuid;group_key uuid;folio uuid;intent uuid;unit uuid;item jsonb;price numeric;total numeric:=0;members integer:=0;expiry timestamptz:=now()+interval '15 minutes';ids uuid[]:='{}';folios uuid[]:='{}';quotes numeric[]:='{}';results jsonb:='[]';n integer:=0;due bigint;remainder bigint;begin
 select *into c from public.conversations where id=p_conversation for update;select *into s from private.whatsapp_booking_sessions where conversation_id=c.id for update;
 if s.reservation_id is not null then return s.reservation_id;end if;
 if s.room_count=1 then
  if jsonb_array_length(s.room_items)=1 then update private.whatsapp_booking_sessions set adults=(room_items->0->>'members')::integer,children=0,type_id=(room_items->0->>'type_id')::uuid where conversation_id=c.id;end if;
  return private.confirm_enquiry_booking_single(c.id,p_source);
 end if;
 select *into p from public.properties where id=c.property_id and archived_at is null for update;
 if p.id is null or c.human_handoff or c.status<>'open'or c.last_inbound_at<=now()-interval '24 hours'or private.is_opted_out(c.property_id,c.wa_contact_id)or not private.tenant_is_active(c.tenant_id)
 or s.step<>'confirm'or s.expires_at<=now()or s.quote_expires_at<=now()or s.connection_id<>c.connection_id or s.phone<>c.wa_contact_id or not private.whatsapp_booking_enabled(p.id)
 or not exists(select 1 from public.messages where id=p_source and conversation_id=c.id and direction='in')then raise exception 'Your booking quote expired. Choose rooms again.'using errcode='22023';end if;
 if jsonb_array_length(s.room_items)<>s.room_count or s.check_in<(now()at time zone p.timezone)::date or s.rate_id is distinct from(select default_rate_plan_id from public.property_settings where property_id=p.id)then raise exception 'Booking details changed. Review a fresh quote.'using errcode='22023';end if;
 select *into merchant from public.hotel_payment_connections where property_id=p.id and status='active'and checkout_enabled;
 if merchant.id is null or p.currency<>'INR'or not exists(select 1 from private.payment_worker_configuration where enabled)then raise exception 'Online deposit payments are not ready for this hotel.'using errcode='22023';end if;
 for item in select *from jsonb_array_elements(s.room_items)loop
  price:=private.frontdesk_price(p.id,(item->>'type_id')::uuid,s.check_in,s.check_out,(item->>'members')::integer,0,s.rate_id);
  if price<2 or price is distinct from(item->>'quote')::numeric then raise exception 'The room price changed. Review a fresh quote before confirming.'using errcode='22023';end if;
  total:=total+price;members:=members+(item->>'members')::integer;
 end loop;
 if total is distinct from s.quote or members<>s.members then raise exception 'The group quote changed. Choose rooms again.'using errcode='22023';end if;
 if c.guest_id is not null then
  select id into gid from public.guests where id=c.guest_id and tenant_id=c.tenant_id and private.campaign_phone(phone)=c.wa_contact_id and lower(trim(full_name))=lower(trim(s.guest_name));
  if gid is null then raise exception 'This number is linked to another guest profile. Reception can verify the booking contact.'using errcode='22023';end if;
 else
  if exists(select 1 from public.whatsapp_guest_authorizations where property_id=p.id and wa_contact_id=c.wa_contact_id)or exists(select 1 from public.guests g join public.reservations r on r.guest_id=g.id and r.property_id=p.id where private.campaign_phone(g.phone)=c.wa_contact_id)then raise exception 'Reception needs to verify the existing guest profile for this number.'using errcode='22023';end if;
  insert into public.guests(tenant_id,full_name,phone)values(p.tenant_id,s.guest_name,'+'||c.wa_contact_id)returning id into gid;
 end if;
 insert into public.reservation_groups(tenant_id,property_id,creation_request_id,name,mode,check_in,check_out,room_count,notes,request_hash)
 values(p.tenant_id,p.id,s.id,left(s.guest_name||' · WhatsApp group',120),'reservation',s.check_in,s.check_out,s.room_count,'WhatsApp group booking. One 50% deposit confirms all rooms.',encode(sha256(convert_to(s.room_items::text,'UTF8')),'hex'))returning id into group_key;
 for item in select *from jsonb_array_elements(s.room_items)loop
  price:=(item->>'quote')::numeric;
  insert into public.reservations(tenant_id,property_id,guest_id,source,booking_origin,check_in,check_out,adults,children,rate_plan_id,total_amount,currency,creation_request_id,notes,status,deposit_expires_at,group_id)
  values(p.tenant_id,p.id,gid,'direct','whatsapp',s.check_in,s.check_out,(item->>'members')::integer,0,s.rate_id,price,p.currency,gen_random_uuid(),'Group contact booked in WhatsApp; awaiting group deposit.','pending_payment',expiry,group_key)returning id into rid;
  unit:=private.frontdesk_allocate(p.id,p.tenant_id,(item->>'type_id')::uuid,s.check_in,s.check_out,rid,null);folio:=private.ensure_folio(rid);
  ids:=array_append(ids,rid);folios:=array_append(folios,folio);quotes:=array_append(quotes,price);if lead_id is null then lead_id:=rid;end if;
  insert into private.whatsapp_booking_contacts(reservation_id,property_id,guest_id,conversation_id,phone,evidence,actor_id)values(rid,p.id,gid,c.id,c.wa_contact_id,'Guest explicitly confirmed the group quote and requested booking/payment/document instructions in WhatsApp. Source message: '||p_source,null);
  insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,details)values(p.tenant_id,p.id,rid,'created',jsonb_build_object('source','whatsapp','unit_id',unit,'group_id',group_key,'source_message',p_source));
  results:=results||jsonb_build_array(jsonb_build_object('id',rid,'status','pending_payment'));
 end loop;
 update public.conversations set guest_id=gid,contact_name=s.guest_name where id=c.id;
 insert into public.hotel_payment_requests(tenant_id,property_id,reservation_id,folio_id,connection_id,request_id,amount,currency,conversation_id,source_message_id,purpose,expires_at,booking_group_id)
 values(p.tenant_id,p.id,lead_id,folios[1],merchant.id,s.id,ceil(total*50)::bigint,'INR',c.id,p_source,'booking_deposit',expiry,group_key)returning id into intent;
 remainder:=ceil(total*50)::bigint-(select sum(floor(x*50))from unnest(quotes)x)::bigint;
 for n in 1..cardinality(ids)loop
  due:=floor(quotes[n]*50)::bigint;if remainder>0 then due:=due+1;remainder:=remainder-1;end if;
  insert into public.hotel_payment_allocations values(intent,ids[n],p.tenant_id,p.id,folios[n],due,n);
 end loop;
 update public.reservation_groups set initial_results=results where id=group_key;
 update private.whatsapp_booking_sessions set step='awaiting_payment',reservation_id=lead_id,group_id=group_key,payment_request_id=intent,deposit_expires_at=expiry,expires_at=expiry,version=version+1 where conversation_id=c.id;
 perform private.capture_whatsapp_event(p.id,lead_id,'booking_deposit_requested','deposit-requested:'||intent,'hotel_payment_requests',intent,null,jsonb_build_object('amount',ceil(total*50)/100));
 perform private.invoke_payment_cloud_worker();perform private.wake_whatsapp_guest_worker();return lead_id;
end $$;
revoke all on function private.confirm_enquiry_booking(uuid,uuid)from public,anon,authenticated,service_role;

create function private.record_group_payment(p_request uuid,p_payment jsonb,p_refunds jsonb)returns void language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;a public.hotel_payment_allocations;rf jsonb;entry record;already numeric;left_amount numeric;take numeric;begin
 select *into job from public.hotel_payment_requests where id=p_request and booking_group_id is not null for update;
 if job.id is null or job.amount is distinct from(select sum(amount)::bigint from public.hotel_payment_allocations where request_id=job.id)or(select count(*)from public.hotel_payment_allocations where request_id=job.id)<2 then raise exception 'Group deposit allocation does not match the payment.'using errcode='22023';end if;
 for a in select *from public.hotel_payment_allocations where request_id=job.id order by position for update loop
  if not exists(select 1 from public.reservations where id=a.reservation_id and property_id=job.property_id and tenant_id=job.tenant_id and group_id=job.booking_group_id)or a.property_id<>job.property_id then raise exception 'Group booking binding changed.'using errcode='22023';end if;
  perform 1 from public.reservations where id=a.reservation_id for update;
  if not exists(select 1 from public.payments where online_request_id=job.id and folio_id=a.folio_id)then
   insert into public.payments(tenant_id,property_id,folio_id,amount,method,reference,online_request_id,provider_payment_id)
   values(job.tenant_id,job.property_id,a.folio_id,a.amount::numeric/100,case p_payment->>'method'when'upi'then'upi'when'card'then'card'when'netbanking'then'bank_transfer'else'other'end,p_payment->>'id',job.id,p_payment->>'id');
  end if;
 end loop;
 for rf in select *from jsonb_array_elements(coalesce(p_refunds,'[]'))loop
  if rf->>'status'<>'processed'then continue;end if;
  if rf->>'payment_id'is distinct from p_payment->>'id'or coalesce(rf->>'id','')!~'^rfnd_[a-zA-Z0-9]+$'or coalesce((rf->>'amount')::bigint,0)<=0 then raise exception 'Refund does not match the group payment.'using errcode='22023';end if;
  if exists(select 1 from public.refunds where provider_refund_id=rf->>'id')then
   if exists(select 1 from public.refunds r join public.payments pay on pay.id=r.payment_id where r.provider_refund_id=rf->>'id'and pay.online_request_id is distinct from job.id)or(select sum(amount)*100 from public.refunds where provider_refund_id=rf->>'id')is distinct from(rf->>'amount')::numeric then raise exception 'Refund binding or amount changed.'using errcode='22023';end if;continue;
  end if;
  left_amount:=(rf->>'amount')::numeric/100;
  select coalesce(sum(r.amount),0)into already from public.refunds r join public.payments pay on pay.id=r.payment_id where pay.online_request_id=job.id;
  if already+left_amount>job.amount::numeric/100 then raise exception 'Refund exceeds recorded group payment.'using errcode='22023';end if;
  for entry in select pay.id,pay.amount-coalesce((select sum(r.amount)from public.refunds r where r.payment_id=pay.id),0)as available from public.payments pay join public.hotel_payment_allocations alloc on alloc.request_id=job.id and alloc.folio_id=pay.folio_id where pay.online_request_id=job.id order by alloc.position for update of pay loop
   take:=least(left_amount,entry.available);if take>0 then insert into public.refunds(tenant_id,property_id,payment_id,amount,reason,provider_refund_id)values(job.tenant_id,job.property_id,entry.id,take,'Verified Razorpay group refund '||(rf->>'id'),rf->>'id');left_amount:=left_amount-take;end if;
   exit when left_amount=0;
  end loop;
  if left_amount<>0 then raise exception 'Group refund could not be fully allocated.'using errcode='22023';end if;
 end loop;
end $$;
revoke all on function private.record_group_payment(uuid,jsonb,jsonb)from public,anon,authenticated,service_role;

-- Keep provider signatures, reference/amount/currency checks and claim leases intact.
do $$declare d text;a integer;b integer;begin
 d:=pg_get_functiondef('public.apply_online_payment(uuid,uuid,jsonb)'::regprocedure);
 a:=strpos(d,'  select id into v_payment from public.payments where provider_payment_id=');b:=strpos(d,E'\n end if;\n update public.hotel_payment_requests set state=');
 if a=0 or b<=a then raise exception 'Payment reconciliation definition changed.';end if;
 d:=left(d,a-1)||E'  if job.booking_group_id is not null then perform private.record_group_payment(job.id,pay,p_snapshot->''refunds'');else\n'||substring(d from a for b-a)||E'\n  end if;'||substring(d from b);execute d;
 -- Manual collection on any member room must wait for the group link to close.
 d:=pg_get_functiondef('private.guard_online_accounting()'::regprocedure);
 d:=replace(d,'where folio_id=new.folio_id and state in','where (folio_id=new.folio_id or exists(select 1 from public.hotel_payment_allocations a where a.request_id=hotel_payment_requests.id and a.folio_id=new.folio_id))and state in');execute d;
end $$;

alter function private.finish_whatsapp_deposit(uuid)rename to finish_whatsapp_deposit_single;
create function private.finish_whatsapp_deposit(p_request uuid)returns void language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;r public.reservations;eligible boolean;begin
 select reservation_id into r.id from public.hotel_payment_requests where id=p_request;perform 1 from public.reservations where id=r.id for update;
 select *into job from public.hotel_payment_requests where id=p_request and purpose='booking_deposit'and state='paid'for update;
 if job.id is null or job.booking_confirmed_at is not null then return;end if;
 if job.booking_group_id is null then perform private.finish_whatsapp_deposit_single(p_request);if(select status from public.reservations where id=job.reservation_id)='confirmed'then update public.hotel_payment_requests set booking_confirmed_at=now()where id=job.id;end if;return;end if;
 perform 1 from public.reservations where id in(select reservation_id from public.hotel_payment_allocations where request_id=job.id)order by id for update;
 if not exists(select 1 from public.hotel_payment_allocations a join public.reservations rr on rr.id=a.reservation_id where a.request_id=job.id and rr.status<>'confirmed')then return;end if;
 eligible:=not exists(select 1 from public.hotel_payment_allocations a join public.reservations rr on rr.id=a.reservation_id where a.request_id=job.id and(rr.status<>'pending_payment'or rr.deposit_expires_at<=now()or not exists(select 1 from public.unit_holds h where h.reservation_id=rr.id and h.active)))and not exists(select 1 from public.refunds rf join public.payments pay on pay.id=rf.payment_id where pay.online_request_id=job.id);
 if eligible then
  update public.reservations set status='confirmed',deposit_expires_at=null where id in(select reservation_id from public.hotel_payment_allocations where request_id=job.id);
  update private.whatsapp_booking_sessions set step='booked',version=version+1 where payment_request_id=job.id;
  update public.hotel_payment_requests set booking_confirmed_at=now()where id=job.id;
  perform private.capture_whatsapp_event(job.property_id,job.reservation_id,'booking_deposit_paid','deposit-paid:'||job.id,'hotel_payment_requests',job.id,'paid',jsonb_build_object('amount',job.amount::numeric/100,'group_id',job.booking_group_id));
 else
  update public.reservations set status='cancelled',notes=left(coalesce(notes,'')||E'\nGroup deposit received after hold ended; staff review required.',2000)where id in(select reservation_id from public.hotel_payment_allocations where request_id=job.id)and status='pending_payment';
  update public.unit_holds h set active=false where h.active and h.reservation_id in(select a.reservation_id from public.hotel_payment_allocations a join public.reservations rr on rr.id=a.reservation_id where a.request_id=job.id and rr.status='cancelled');
  update private.whatsapp_booking_sessions set step='cancelled',version=version+1 where payment_request_id=job.id;
  update public.hotel_payment_requests set last_error='Group payment requires staff review: one or more room holds ended or payment was refunded. No pending rooms were confirmed.',reconcile_needed=false where id=job.id;
  insert into public.reservation_events(tenant_id,property_id,reservation_id,event_type,details)select job.tenant_id,job.property_id,job.reservation_id,'deposit_needs_review',jsonb_build_object('payment_request',job.id,'group_id',job.booking_group_id)where not exists(select 1 from public.reservation_events where reservation_id=job.reservation_id and event_type='deposit_needs_review'and details->>'payment_request'=job.id::text);
 end if;
end $$;

create or replace function private.expire_whatsapp_deposits()returns integer language plpgsql security definer set search_path=''as $$
declare r public.reservations;job public.hotel_payment_requests;n integer:=0;begin
 -- Start with the payment's lead room, matching the reconciliation lock order.
 for r in select rr.*from public.reservations rr where rr.status='pending_payment'and rr.deposit_expires_at<=now()and not exists(select 1 from public.hotel_payment_allocations a join public.hotel_payment_requests j on j.id=a.request_id where a.reservation_id=rr.id and j.reservation_id<>rr.id)order by rr.deposit_expires_at limit 100 for update skip locked loop
  select *into job from public.hotel_payment_requests where reservation_id=r.id and purpose='booking_deposit'for update;
  if job.state='paid'then continue;end if;
  perform 1 from public.reservations where id in(select reservation_id from public.hotel_payment_allocations where request_id=job.id)order by id for update;
  update public.reservations set status='cancelled',notes=left(coalesce(notes,'')||E'\nDeposit hold expired before verified payment.',2000)where status='pending_payment'and(id=r.id or id in(select reservation_id from public.hotel_payment_allocations where request_id=job.id));
  update public.unit_holds set active=false where active and(reservation_id=r.id or reservation_id in(select reservation_id from public.hotel_payment_allocations where request_id=job.id));
  update public.hotel_payment_requests set state=case when not creation_started and lease is null then'expired'else'cancel_pending'end,reconcile_needed=creation_started,next_check_at=now()where id=job.id;
  update private.whatsapp_booking_sessions set step='cancelled',version=version+1 where reservation_id=r.id;
  perform private.capture_whatsapp_event(r.property_id,r.id,'booking_payment_expired','deposit-expired:'||r.id,'hotel_payment_requests',job.id,null,jsonb_build_object('amount',job.amount::numeric/100));n:=n+1;
 end loop;return n;
end $$;

-- A group receives one booking welcome; each room keeps its own later stay events.
do $$declare d text;begin
 d:=pg_get_functiondef('private.capture_whatsapp_event(uuid,uuid,text,text,text,uuid,text,jsonb,timestamptz,timestamptz)'::regprocedure);
 d:=replace(d,'begin',E'begin\n if p_event=''booking_confirmed''and exists(select 1 from public.hotel_payment_allocations a join public.hotel_payment_requests j on j.id=a.request_id where a.reservation_id=p_reservation and j.booking_group_id is not null and j.reservation_id<>p_reservation)then return;end if;');execute d;
end $$;

alter function private.payment_guest_notice(uuid,boolean)rename to payment_guest_notice_single;
create function private.payment_guest_notice(p_request uuid,p_paid boolean)returns uuid language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;c public.conversations;r public.reservations;p public.properties;s public.property_settings;body text;payload jsonb;mid uuid;mode text;total numeric;rooms integer;begin
 select *into job from public.hotel_payment_requests where id=p_request;select *into r from public.reservations where id=job.reservation_id;
 if p_paid and job.booking_confirmed_at is not null and(job.receipt_message_id is not null or r.status<>'confirmed')then return null;end if;
 if job.purpose<>'booking_deposit'or(job.booking_group_id is null and not(p_paid and r.status='confirmed'))then return private.payment_guest_notice_single(p_request,p_paid);end if;
 select *into c from public.conversations where id=job.conversation_id;select *into p from public.properties where id=job.property_id;select *into s from public.property_settings where property_id=p.id;
 if c.guest_id is distinct from r.guest_id or c.wa_contact_id is distinct from(select private.campaign_phone(phone)from public.guests where id=r.guest_id)or not exists(select 1 from private.whatsapp_booking_contacts where reservation_id=r.id and conversation_id=c.id and phone=c.wa_contact_id)then return null;end if;
 if job.booking_group_id is null then total:=r.total_amount;rooms:=1;else select sum(rr.total_amount),count(*)into total,rooms from public.hotel_payment_allocations a join public.reservations rr on rr.id=a.reservation_id where a.request_id=job.id;end if;
 if p_paid then
  if r.status<>'confirmed'or exists(select 1 from public.hotel_payment_allocations a join public.reservations rr on rr.id=a.reservation_id where a.request_id=job.id and rr.status<>'confirmed')then
   body:='Your group payment was received, but the room holds ended or changed. The group is not confirmed. Reception will arrange a refund or help with a new booking. Please do not pay again.';
  else
   if job.receipt_message_id is not null then return null;end if;
   body:=case when rooms>1 then'Your group booking is confirmed: '||rooms||' rooms at 'else'Your booking is confirmed at 'end||left(p.name,150)||'.'||E'\nCheck-in: '||to_char(r.check_in,'DD-MM-YYYY')||' from '||to_char(s.check_in_time,'HH24:MI')||E'\nCheck-out: '||to_char(r.check_out,'DD-MM-YYYY')||' by '||to_char(s.check_out_time,'HH24:MI')||' ('||p.timezone||')'||E'\nDeposit received: INR '||(job.amount::numeric/100)||E'\nRemaining room balance: INR '||(total-job.amount::numeric/100)||', plus extras.'||case when rooms>1 then E'\nOne group is visible to reception. Send Hi to choose a room booking for documents and stay help.'else E'\nSend Hi for documents and stay help.'end;
  end if;
 else
  if job.state<>'ready'or r.status<>'pending_payment'or r.deposit_expires_at<=now()or job.link_message_id is not null then return null;end if;
  select hc.mode into mode from public.hotel_payment_connections hc where id=job.connection_id;
  body:='Pay one 50% group deposit of INR '||(job.amount::numeric/100)||' for all '||rooms||' rooms. Remaining room balance: INR '||(total-job.amount::numeric/100)||', plus extras. All rooms are held until '||to_char(r.deposit_expires_at at time zone p.timezone,'DD-MM-YYYY HH24:MI')||' ('||p.timezone||'). The group confirms only after verified payment.'||case when mode='test'then' TEST MODE: no real money is collected.'else''end;
  payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','cta_url','body',jsonb_build_object('text',body),'action',jsonb_build_object('name','cta_url','parameters',jsonb_build_object('display_text','Pay group deposit','url',job.short_url))));
 end if;
 mid:=private.queue_journey_reply(c.id,job.source_message_id,case when p_paid then'booking_summary:'else'deposit_link:'end||job.id,body,payload,null);
 if mid is not null then update public.messages set payment_request_id=job.id where id=mid;end if;return mid;
end $$;

-- Date and time are present even when the booking welcome uses the native fallback.
do $$declare d text;begin
 d:=pg_get_functiondef('private.whatsapp_native_event_body(uuid,text)'::regprocedure);
 d:=replace(d,'''DD-MM-YYYY'')||''; check-out: ''','''DD-MM-YYYY'')||'' from ''||(select to_char(check_in_time,''HH24:MI'')from public.property_settings where property_id=p.id)||''; check-out: ''');
 d:=replace(d,'''DD-MM-YYYY'')||''. Room total: ''','''DD-MM-YYYY'')||'' by ''||(select to_char(check_out_time,''HH24:MI'')from public.property_settings where property_id=p.id)||'' (''||p.timezone||''). Room total: ''');execute d;
 d:=pg_get_functiondef('private.handle_whatsapp_journey_before_public_info(uuid,uuid,text,text)'::regprocedure);
 d:=replace(d,'its room released','its rooms released');d:=replace(d,'No room is confirmed','No rooms are confirmed');execute d;
 d:=pg_get_functiondef('public.payment_workspace(uuid,uuid)'::regprocedure);
 d:=replace(d,'as mode,purpose,id,','as mode,booking_group_id,(select amount from public.hotel_payment_allocations a where a.request_id=hotel_payment_requests.id and a.reservation_id=p_reservation)as allocated_amount,purpose,id,');
 d:=replace(d,'p_reservation is null or reservation_id=p_reservation','p_reservation is null or reservation_id=p_reservation or exists(select 1 from public.hotel_payment_allocations a where a.request_id=hotel_payment_requests.id and a.reservation_id=p_reservation)');execute d;
end $$;
revoke all on function private.finish_whatsapp_deposit_single(uuid),private.finish_whatsapp_deposit(uuid),private.payment_guest_notice_single(uuid,boolean),private.payment_guest_notice(uuid,boolean)from public,anon,authenticated,service_role;

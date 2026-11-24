alter table public.properties add column payment_test_mode boolean not null default false;
-- Hotel-owned Razorpay Test Mode accounts. Secrets are service-only, encrypted with connection-bound AAD.
create table public.hotel_payment_connections(
 id uuid primary key,tenant_id uuid not null,property_id uuid not null,provider text not null default 'razorpay'check(provider='razorpay'),
 mode text not null check(mode='test'),status text not null default 'active'check(status in('active','disconnected')),
 key_hint text not null,checkout_enabled boolean not null default false,version integer not null default 1,
 webhook_seen_at timestamptz,created_at timestamptz not null default now(),created_by uuid references public.profiles(id),
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id),unique(id,property_id)
);
create unique index hotel_payment_active on public.hotel_payment_connections(property_id)where status='active';
create table private.hotel_payment_credentials(connection_id uuid primary key references public.hotel_payment_connections(id),ciphertext text not null);
revoke all on private.hotel_payment_credentials from public,anon,authenticated,service_role;
create table public.hotel_payment_requests(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null,property_id uuid not null,reservation_id uuid not null,folio_id uuid not null,
 connection_id uuid not null,request_id uuid not null,amount bigint not null check(amount>0),currency text not null check(currency='INR'),
 state text not null default 'pending'check(state in('pending','creating','unknown','ready','cancel_pending','cancelled','expired','paid','failed')),
 provider_link_id text,provider_order_id text,provider_payment_id text,short_url text,expires_at timestamptz not null default(now()+interval '30 minutes'),
 conversation_id uuid references public.conversations(id),source_message_id uuid references public.messages(id),link_message_id uuid references public.messages(id),receipt_message_id uuid references public.messages(id),
 creation_started boolean not null default false,lease uuid,locked_at timestamptz,attempts integer not null default 0,next_check_at timestamptz not null default now(),reconcile_needed boolean not null default true,
 last_error text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),created_by uuid references public.profiles(id),
 unique(property_id,request_id),unique(connection_id,provider_link_id),
 foreign key(connection_id,property_id)references public.hotel_payment_connections(id,property_id),
 foreign key(reservation_id,property_id)references public.reservations(id,property_id),foreign key(folio_id,property_id)references public.folios(id,property_id),
 foreign key(property_id,tenant_id)references public.properties(id,tenant_id)
);
create unique index hotel_payment_one_open on public.hotel_payment_requests(reservation_id)where state in('pending','creating','unknown','ready','cancel_pending');
create index hotel_payment_due on public.hotel_payment_requests(next_check_at)where reconcile_needed;
create table private.hotel_payment_webhooks(connection_id uuid not null,event_id text not null,body_hash text not null,created_at timestamptz not null default now(),primary key(connection_id,event_id));
revoke all on private.hotel_payment_webhooks from public,anon,authenticated,service_role;
alter table public.payments add column online_request_id uuid references public.hotel_payment_requests(id),add column provider_payment_id text unique;
alter table public.refunds add column provider_refund_id text unique;
alter table public.messages add column payment_request_id uuid references public.hotel_payment_requests(id);
alter table public.hotel_payment_connections enable row level security;
alter table public.hotel_payment_requests enable row level security;
create policy hotel_payment_connections_read on public.hotel_payment_connections for select to authenticated using(private.has_permission(property_id,'billing.manage')or private.has_permission(property_id,'finance.read'));
create policy hotel_payment_requests_read on public.hotel_payment_requests for select to authenticated using(private.has_permission(property_id,'billing.manage')or private.has_permission(property_id,'finance.read'));
revoke all on public.hotel_payment_connections,public.hotel_payment_requests from public,anon,authenticated;
grant select on public.hotel_payment_connections,public.hotel_payment_requests to authenticated;
grant all on public.hotel_payment_connections,public.hotel_payment_requests to service_role;

create table private.payment_worker_configuration(id boolean primary key default true check(id),origin text not null,secret_id uuid not null,enabled boolean not null default false,last_success_at timestamptz,last_result text);
revoke all on private.payment_worker_configuration from public,anon,authenticated,service_role;
create function public.configure_payment_cloud_worker(p_enabled boolean)returns void language plpgsql security definer set search_path=''as $$
begin
 insert into private.payment_worker_configuration(id,origin,secret_id,enabled)select true,origin,secret_id,p_enabled from private.whatsapp_worker_configuration where id=true
 on conflict(id)do update set origin=excluded.origin,secret_id=excluded.secret_id,enabled=excluded.enabled;
 if not found then raise exception 'Configure the platform worker secret first.'using errcode='22023';end if;
end $$;
create function private.invoke_payment_cloud_worker()returns bigint language plpgsql security definer set search_path=''as $$
declare c private.payment_worker_configuration;token text;request_id bigint;
begin
 select *into c from private.payment_worker_configuration where id=true and enabled;if c.id is null then return null;end if;
 select decrypted_secret into token from vault.decrypted_secrets where id=c.secret_id;
 select net.http_post(url:=c.origin||'/functions/v1/payments-worker',headers:=jsonb_build_object('Content-Type','application/json','X-Worker-Secret',token),body:='{}',timeout_milliseconds:=120000)into request_id;return request_id;
end $$;
create function public.record_payment_worker_health(p_ok boolean)returns void language sql security definer set search_path=''as $$
 update private.payment_worker_configuration set last_result=case when p_ok then'ok'else'error'end,last_success_at=case when p_ok then now()else last_success_at end where id=true
$$;
select cron.schedule('hospitality-payment-worker','* * * * *','select private.invoke_payment_cloud_worker()');

create function public.payment_workspace(p_property uuid,p_reservation uuid default null)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 if not(private.has_permission(p_property,'billing.manage')or private.has_permission(p_property,'finance.read'))then raise exception 'Billing access required.'using errcode='42501';end if;
 return jsonb_build_object('connection',(select to_jsonb(c)from public.hotel_payment_connections c where property_id=p_property and status='active'),
 'test_hotel',(select payment_test_mode from public.properties where id=p_property),'can_configure',private.has_permission(p_property,'staff.manage'),'can_collect',private.has_permission(p_property,'billing.manage'),
 'worker',(select jsonb_build_object('enabled',enabled,'last_success_at',last_success_at,'last_result',last_result)from private.payment_worker_configuration where id=true),
 'requests',coalesce((select jsonb_agg(v order by created_at desc)from(select id,reservation_id,connection_id,amount,currency,state,provider_link_id,provider_payment_id,short_url,expires_at,last_error,created_at from public.hotel_payment_requests where property_id=p_property and(p_reservation is null or reservation_id=p_reservation)order by created_at desc limit 20)v),'[]'::jsonb));
end $$;
create function public.payment_connection_commit(p_property uuid,p_actor uuid,p_connection uuid,p_key_hint text,p_ciphertext text,p_test_hotel boolean)returns uuid language plpgsql security definer set search_path=''as $$
declare tenant uuid;
begin
 if not private.whatsapp_actor_allowed(p_property,p_actor)then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 select tenant_id into tenant from public.properties where id=p_property and archived_at is null for update;
 if tenant is null then raise exception 'Hotel is unavailable.'using errcode='22023';end if;
 if p_test_hotel is not true then raise exception 'Use a dedicated test hotel for Test Mode payments.'using errcode='22023';end if;
 if p_connection is null or p_key_hint!~'^rzp_test_.*[a-zA-Z0-9]{4}$'or length(p_key_hint)>40 or p_ciphertext not like'v1.%'then raise exception 'Invalid Test Mode connection.'using errcode='22023';end if;
 if exists(select 1 from public.hotel_payment_requests where property_id=p_property and state in('pending','creating','unknown','ready','cancel_pending'))then raise exception 'Resolve or cancel open payment links before replacing this account.'using errcode='22023';end if;
 update public.properties set payment_test_mode=true where id=p_property;
 update public.hotel_payment_connections set status='disconnected',checkout_enabled=false,version=version+1 where property_id=p_property and status='active';
 insert into public.hotel_payment_connections(id,tenant_id,property_id,mode,key_hint,created_by)values(p_connection,tenant,p_property,'test',p_key_hint,p_actor);
 insert into private.hotel_payment_credentials values(p_connection,p_ciphertext);return p_connection;
end $$;
create function public.payment_credential(p_connection uuid)returns jsonb language sql stable security definer set search_path=''as $$
 select jsonb_build_object('connection',to_jsonb(c),'ciphertext',s.ciphertext)from public.hotel_payment_connections c join private.hotel_payment_credentials s on s.connection_id=c.id where c.id=p_connection
$$;
create function public.payment_connection_action(p_property uuid,p_connection uuid,p_version integer,p_action text)returns void language plpgsql security definer set search_path=''as $$
declare c public.hotel_payment_connections;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'Hotel administrator access required.'using errcode='42501';end if;
 select *into c from public.hotel_payment_connections where id=p_connection and property_id=p_property and status='active'for update;
 if c.id is null or c.version is distinct from p_version then raise exception 'Connection changed. Refresh before saving.'using errcode='40001';end if;
 if p_action is null or p_action not in('enable','pause','disconnect')then raise exception 'Invalid connection action.'using errcode='22023';end if;
 if p_action='disconnect'and exists(select 1 from public.hotel_payment_requests where connection_id=c.id and state in('pending','creating','unknown','ready','cancel_pending'))then raise exception 'Cancel or reconcile open links before disconnecting.'using errcode='22023';end if;
 update public.hotel_payment_connections set checkout_enabled=p_action='enable',status=case when p_action='disconnect'then'disconnected'else'active'end,version=version+1 where id=c.id;
end $$;

create function private.request_online_payment(p_reservation uuid,p_request uuid,p_conversation uuid default null,p_source uuid default null)returns uuid language plpgsql security definer set search_path=''as $$
declare r public.reservations;c public.hotel_payment_connections;f uuid;balance numeric;job public.hotel_payment_requests;
begin
 select *into r from public.reservations where id=p_reservation for update;
 if r.id is null or r.status<>'checked_in'or not private.tenant_is_active(r.tenant_id)or exists(select 1 from public.properties where id=r.property_id and archived_at is not null)then raise exception 'Online checkout payments require an active in-house stay.'using errcode='22023';end if;
 select *into c from public.hotel_payment_connections where property_id=r.property_id and status='active'and checkout_enabled;
 if c.id is null or r.currency<>'INR'or not(select payment_test_mode from public.properties where id=r.property_id)then raise exception 'Enable this hotel’s Razorpay Test Mode account for INR checkout payments.'using errcode='22023';end if;
 if exists(select 1 from public.orders where reservation_id=r.id and status not in('served','cancelled'))then raise exception 'Finish or cancel outstanding food orders before preparing the final payment.'using errcode='22023';end if;
 if p_conversation is not null and(p_reservation is distinct from private.journey_stay(p_conversation)or not exists(select 1 from public.conversations cv join public.whatsapp_guest_authorizations a on a.conversation_id=cv.id and a.guest_id=r.guest_id and a.status='granted'where cv.id=p_conversation and cv.property_id=r.property_id and not cv.human_handoff and cv.status='open'and cv.last_inbound_at>now()-interval '24 hours'and not private.is_opted_out(r.property_id,cv.wa_contact_id)))then raise exception 'Guest verification and an open WhatsApp reply window are required. Ask the guest to send Hi.'using errcode='22023';end if;
 select *into job from public.hotel_payment_requests where property_id=r.property_id and request_id=p_request;
 if job.id is not null then if job.reservation_id<>r.id then raise exception 'Request belongs to another stay.'using errcode='22023';end if;return job.id;end if;
 select *into job from public.hotel_payment_requests where reservation_id=r.id and state in('pending','creating','unknown','ready','cancel_pending');
 if job.id is not null then
  if p_conversation is not null then update public.hotel_payment_requests set conversation_id=p_conversation,source_message_id=p_source,link_message_id=case when source_message_id is distinct from p_source then null else link_message_id end,reconcile_needed=true,next_check_at=now()where id=job.id;end if;
  perform private.invoke_payment_cloud_worker();return job.id;
 end if;
 f:=private.post_room_nights(r.id,r.check_out-1);balance:=private.reservation_balance(r.id);
 if balance<=0 then raise exception 'There is no positive checkout balance to collect.'using errcode='22023';end if;
 insert into public.hotel_payment_requests(tenant_id,property_id,reservation_id,folio_id,connection_id,request_id,amount,currency,conversation_id,source_message_id,created_by)
 values(r.tenant_id,r.property_id,r.id,f,c.id,p_request,(balance*100)::bigint,'INR',p_conversation,p_source,auth.uid())returning *into job;
 perform private.invoke_payment_cloud_worker();return job.id;
end $$;
create function public.request_online_payment(p_property uuid,p_reservation uuid,p_request uuid,p_send boolean default false)returns uuid language plpgsql security definer set search_path=''as $$
declare cid uuid;
begin
 if not private.has_permission(p_property,'billing.manage')or not exists(select 1 from public.reservations where id=p_reservation and property_id=p_property)then raise exception 'Billing access required for this stay.'using errcode='42501';end if;
 if p_request is null then raise exception 'Refresh the payment form.'using errcode='22023';end if;
 if p_send then select a.conversation_id into cid from public.whatsapp_guest_authorizations a join public.reservations r on r.guest_id=a.guest_id and r.property_id=a.property_id where r.id=p_reservation and a.status='granted';if cid is null then raise exception 'Verify the guest’s WhatsApp preference first.'using errcode='22023';end if;end if;
 return private.request_online_payment(p_reservation,p_request,cid,null);
end $$;
create function public.cancel_online_payment(p_property uuid,p_request uuid)returns void language plpgsql security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'billing.manage')then raise exception 'Billing access required.'using errcode='42501';end if;
 update public.hotel_payment_requests set state='cancel_pending',reconcile_needed=true,next_check_at=now()where id=p_request and property_id=p_property and state in('pending','unknown','ready');
 if not found then raise exception 'This payment is processing or already complete. Refresh and reconcile it first.'using errcode='22023';end if;perform private.invoke_payment_cloud_worker();
end $$;
create function public.reconcile_online_payment(p_property uuid,p_request uuid)returns void language plpgsql security definer set search_path=''as $$
begin
 if not private.has_permission(p_property,'billing.manage')then raise exception 'Billing access required.'using errcode='42501';end if;
 update public.hotel_payment_requests set reconcile_needed=true,next_check_at=now()where id=p_request and property_id=p_property and state not in('failed');
 if not found then raise exception 'Payment request not found.'using errcode='22023';end if;perform private.invoke_payment_cloud_worker();
end $$;

create function public.claim_online_payment()returns jsonb language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;
begin
 update public.hotel_payment_requests set lease=null,state=case when state='creating'then'unknown'else state end,reconcile_needed=true,next_check_at=now()where locked_at<now()-interval '2 minutes'and lease is not null;
 select *into job from public.hotel_payment_requests where reconcile_needed and next_check_at<=now()and lease is null and state in('pending','unknown','ready','cancel_pending','paid','expired','cancelled')order by next_check_at,id limit 1 for update skip locked;
 if job.id is null then return null;end if;
 update public.hotel_payment_requests set lease=gen_random_uuid(),locked_at=now(),attempts=attempts+1,creation_started=creation_started or state='pending',state=case when state='pending'then'creating'else state end where id=job.id returning *into job;
 return to_jsonb(job)||jsonb_build_object('operation',case when job.state='creating'then'create'when job.state='cancel_pending'then'cancel'else'reconcile'end,'reference',replace(job.id::text,'-',''),'credential',(select ciphertext from private.hotel_payment_credentials where connection_id=job.connection_id));
end $$;
create function public.fail_online_payment(p_request uuid,p_lease uuid,p_error text)returns void language plpgsql security definer set search_path=''as $$
begin
 update public.hotel_payment_requests set state=case when state='creating'then'unknown'else state end,lease=null,locked_at=null,last_error=left(p_error,300),next_check_at=now()+interval '1 minute',updated_at=now()where id=p_request and lease=p_lease;
end $$;
create function public.notify_payment_webhook(p_connection uuid,p_event text,p_hash text,p_reference text,p_link text,p_order text,p_payment text)returns boolean language plpgsql security definer set search_path=''as $$
begin
 if length(p_event)>200 or p_hash!~'^[a-f0-9]{64}$'then raise exception 'Invalid webhook.'using errcode='22023';end if;
 if exists(select 1 from private.hotel_payment_webhooks where connection_id=p_connection and event_id=p_event and body_hash<>p_hash)then raise exception 'Webhook event changed.'using errcode='22023';end if;
 insert into private.hotel_payment_webhooks values(p_connection,p_event,p_hash,now())on conflict do nothing;if not found then return false;end if;
 update public.hotel_payment_connections set webhook_seen_at=now()where id=p_connection;
 update public.hotel_payment_requests set reconcile_needed=true,next_check_at=now()where connection_id=p_connection and(provider_link_id=p_link or provider_order_id=p_order or provider_payment_id=p_payment or replace(id::text,'-','')=p_reference);
 perform private.invoke_payment_cloud_worker();return true;
end $$;

create function private.payment_guest_notice(p_request uuid,p_paid boolean)returns uuid language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;mid uuid;body text;payload jsonb;balance numeric;buttons jsonb;
begin
 select *into job from public.hotel_payment_requests where id=p_request;
 if job.conversation_id is null or job.reservation_id is distinct from private.journey_stay(job.conversation_id)then return null;end if;
 if(p_paid and job.receipt_message_id is not null)or(not p_paid and job.link_message_id is not null)then return null;end if;
 balance:=private.reservation_balance(job.reservation_id);
 if p_paid then
  body:='Test payment received: '||(job.amount::numeric/100)::text||' INR. Your current balance is '||balance||' INR. No real money was collected.';
  if balance=0 and exists(select 1 from public.reservations where id=job.reservation_id and status='checked_in')then
   body:=body||' Ready to leave? Confirm checkout below.';buttons:=jsonb_build_array(private.journey_button(job.conversation_id,job.reservation_id,'confirm_checkout','Confirm checkout'),private.journey_button(job.conversation_id,job.reservation_id,'bill','View bill'));
   payload:=private.journey_buttons_payload(body,buttons);
  end if;
 else
  if balance*100<>job.amount or job.state<>'ready'then return null;end if;
  body:='Your final checkout balance is '||(job.amount::numeric/100)::text||' INR. This is a Razorpay Test Mode link; use test payment details only. After payment, return here to confirm checkout.';
  payload:=jsonb_build_object('type','interactive','interactive',jsonb_build_object('type','cta_url','body',jsonb_build_object('text',body),'action',jsonb_build_object('name','cta_url','parameters',jsonb_build_object('display_text','Pay securely · test','url',job.short_url))));
 end if;
 mid:=private.queue_journey_reply(job.conversation_id,job.source_message_id,case when p_paid then'online_payment_receipt:'else'online_payment_link:'end||job.id::text,body,payload,job.reservation_id);
 if mid is not null then update public.messages set payment_request_id=job.id where id=mid;end if;return mid;
end $$;

create function public.apply_online_payment(p_request uuid,p_lease uuid,p_snapshot jsonb)returns boolean language plpgsql security definer set search_path=''as $$
declare job public.hotel_payment_requests;r public.reservations;link jsonb:=p_snapshot->'link';pay jsonb:=p_snapshot->'payment';rf jsonb;v_payment uuid;mid uuid;balance numeric;status text;
begin
 select reservation_id into v_payment from public.hotel_payment_requests where id=p_request;
 perform 1 from public.reservations where id=v_payment for update;
 select *into job from public.hotel_payment_requests where id=p_request for update;if job.id is null or job.lease is distinct from p_lease then return false;end if;
 if link is null or link='null'::jsonb then
  if coalesce((p_snapshot->>'cancelled')::boolean,false)and not job.creation_started then update public.hotel_payment_requests set state='cancelled',reconcile_needed=false,lease=null,locked_at=null,last_error=null where id=job.id;return true;end if;
  if coalesce((p_snapshot->>'expired')::boolean,false)and not job.creation_started and job.expires_at<=now()then update public.hotel_payment_requests set state='expired',reconcile_needed=false,lease=null,locked_at=null,last_error=null where id=job.id;return true;end if;
  update public.hotel_payment_requests set state=case when job.state='cancel_pending'then'cancel_pending'else'unknown'end,lease=null,locked_at=null,last_error='Provider creation is still being reconciled. No duplicate link was created.',next_check_at=now()+interval '1 minute',reconcile_needed=true where id=job.id;return true;
 end if;
 if link->>'reference_id'is distinct from replace(job.id::text,'-','')or(link->>'amount')::bigint is distinct from job.amount or link->>'currency'is distinct from'INR'or link#>>'{notes,property_id}'is distinct from job.property_id::text or link#>>'{notes,reservation_id}'is distinct from job.reservation_id::text or coalesce(link->>'id','')!~'^plink_[a-zA-Z0-9]+$'then raise exception 'Provider payment does not match this hotel bill.'using errcode='22023';end if;
 if job.provider_link_id is not null and job.provider_link_id<>link->>'id'then raise exception 'Payment link binding changed.'using errcode='22023';end if;
 if coalesce(link->>'short_url','')!~'^https://rzp\.(io|to)/[a-zA-Z0-9/_-]+$'then raise exception 'Invalid provider payment URL.'using errcode='22023';end if;
 status:=link->>'status';if status is null or status not in('created','paid','cancelled','expired')then raise exception 'Unsupported payment status; review with reception.'using errcode='22023';end if;
 if job.provider_payment_id is not null and status<>'paid'then raise exception 'A captured payment cannot be reverted by an older provider status.'using errcode='22023';end if;
 if status='paid'then
  if coalesce(link->>'order_id','')!~'^order_[a-zA-Z0-9]+$'or pay is null or pay->>'status'is distinct from'captured'or(pay->>'captured')::boolean is not true or(pay->>'amount')::bigint is distinct from job.amount or pay->>'currency'is distinct from'INR'or pay->>'order_id'is distinct from link->>'order_id'or coalesce(pay->>'id','')!~'^pay_[a-zA-Z0-9]+$'then raise exception 'A matching captured payment is required.'using errcode='22023';end if;
  if exists(select 1 from public.payments where provider_payment_id=pay->>'id'and online_request_id is distinct from job.id)then raise exception 'Payment already belongs to another bill.'using errcode='22023';end if;
  update public.hotel_payment_requests set state='paid',provider_payment_id=pay->>'id'where id=job.id;
  select id into v_payment from public.payments where provider_payment_id=pay->>'id';
  if v_payment is null then insert into public.payments(tenant_id,property_id,folio_id,amount,method,reference,online_request_id,provider_payment_id)values(job.tenant_id,job.property_id,job.folio_id,job.amount::numeric/100,case pay->>'method'when'upi'then'upi'when'card'then'card'when'netbanking'then'bank_transfer'else'other'end,pay->>'id',job.id,pay->>'id')returning id into v_payment;end if;
  for rf in select *from jsonb_array_elements(coalesce(p_snapshot->'refunds','[]'))loop
   if rf->>'status'='processed'then
    if rf->>'payment_id'is distinct from pay->>'id'or coalesce(rf->>'id','')!~'^rfnd_[a-zA-Z0-9]+$'or coalesce((rf->>'amount')::bigint,0)<=0 then raise exception 'Refund does not match the payment.'using errcode='22023';end if;
    if not exists(select 1 from public.refunds where provider_refund_id=rf->>'id')then
     if coalesce((select sum(amount)from public.refunds where public.refunds.payment_id=v_payment),0)+(rf->>'amount')::numeric/100>job.amount::numeric/100 then raise exception 'Refund exceeds recorded payment.'using errcode='22023';end if;
     insert into public.refunds(tenant_id,property_id,payment_id,amount,reason,provider_refund_id)values(job.tenant_id,job.property_id,v_payment,(rf->>'amount')::numeric/100,'Verified Razorpay refund '||(rf->>'id'),rf->>'id');
    end if;
   end if;
  end loop;
 end if;
 update public.hotel_payment_requests set state=case status when'paid'then'paid'when'cancelled'then'cancelled'when'expired'then'expired'else case when private.reservation_balance(job.reservation_id)*100<>job.amount then'cancel_pending'else'ready'end end,
 provider_link_id=link->>'id',provider_order_id=link->>'order_id',short_url=link->>'short_url',lease=null,locked_at=null,last_error=null,updated_at=now(),next_check_at=now()+interval '1 minute',reconcile_needed=status='created'where id=job.id;
 if status='paid'then mid:=private.payment_guest_notice(job.id,true);update public.hotel_payment_requests set receipt_message_id=coalesce(receipt_message_id,mid)where id=job.id;
 elsif status='created'then mid:=private.payment_guest_notice(job.id,false);update public.hotel_payment_requests set link_message_id=coalesce(link_message_id,mid)where id=job.id;end if;
 perform private.wake_whatsapp_guest_worker();return true;
end $$;

-- Never manually account for an online transaction or refund as if the gateway moved funds.
create function private.guard_online_accounting()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if tg_table_name='payments'then
  if new.online_request_id is null and exists(select 1 from public.hotel_payment_requests where folio_id=new.folio_id and state in('pending','creating','unknown','ready','cancel_pending'))then raise exception 'An online payment is open. Reconcile or cancel its link before taking another payment.'using errcode='22023';end if;
 elsif new.provider_refund_id is null and exists(select 1 from public.payments where id=new.payment_id and online_request_id is not null)then raise exception 'Refund this payment in Razorpay. Verified gateway refunds update the folio automatically.'using errcode='22023';end if;return new;
end $$;
create trigger online_payment_guard before insert on public.payments for each row execute function private.guard_online_accounting();
create trigger online_refund_guard before insert on public.refunds for each row execute function private.guard_online_accounting();

-- Offer online settlement in chat; checkout itself retains the existing zero-balance/order guards.
do $$declare definition text;needle text:=' elsif action in(''checkout'',''confirm_checkout'')then';replacement text;
begin
 definition:=pg_get_functiondef('private.handle_whatsapp_journey(uuid,uuid,text,text)'::regprocedure);
 if position(needle in definition)=0 then raise exception 'Checkout handler changed; review the payment integration.';end if;
 replacement:=needle||E'\n  if action=''checkout''and r.status=''checked_in''and exists(select 1 from public.hotel_payment_connections where property_id=r.property_id and status=''active''and checkout_enabled)then\n   perform private.post_room_nights(r.id,r.check_out-1);balance:=private.reservation_balance(r.id);\n   if balance>0 then\n    target:=private.request_online_payment(r.id,p_source,c.id,p_source);\n    body:=''Preparing your secure Razorpay Test Mode payment link. No real money will be collected. Your bill must be settled before checkout.'';\n    perform private.queue_journey_reply(c.id,p_source,''payment_preparing'',body,null,r.id);return 1;\n   end if;\n  end if;';
 execute replace(definition,needle,replacement);
end $$;

alter function private.inbox_delivery_error(uuid)rename to inbox_delivery_error_before_payments;
revoke all on function private.inbox_delivery_error_before_payments(uuid)from public,anon,authenticated,service_role;
create function private.inbox_delivery_error(p_message uuid)returns text language plpgsql stable security definer set search_path=''as $$
declare why text;job public.hotel_payment_requests;m public.messages;
begin
 why:=private.inbox_delivery_error_before_payments(p_message);if why is not null then return why;end if;
 select *into m from public.messages where id=p_message;if m.payment_request_id is null then return null;end if;
 select *into job from public.hotel_payment_requests where id=m.payment_request_id;
 if m.journey_purpose like'online_payment_link:%'and(job.state<>'ready'or job.expires_at<=now()or private.reservation_balance(job.reservation_id)*100<>job.amount)then return 'Payment link expired, closed or bill changed. Request a fresh link.';end if;
 return null;
end $$;
revoke all on function private.inbox_delivery_error(uuid),private.request_online_payment(uuid,uuid,uuid,uuid),private.payment_guest_notice(uuid,boolean),private.guard_online_accounting(),private.invoke_payment_cloud_worker()from public,anon,authenticated,service_role;
revoke all on function public.payment_workspace(uuid,uuid),public.request_online_payment(uuid,uuid,uuid,boolean),public.cancel_online_payment(uuid,uuid),public.reconcile_online_payment(uuid,uuid),public.payment_connection_action(uuid,uuid,integer,text)from public,anon;
grant execute on function public.payment_workspace(uuid,uuid),public.request_online_payment(uuid,uuid,uuid,boolean),public.cancel_online_payment(uuid,uuid),public.reconcile_online_payment(uuid,uuid),public.payment_connection_action(uuid,uuid,integer,text)to authenticated;
revoke all on function public.payment_connection_commit(uuid,uuid,uuid,text,text,boolean),public.payment_credential(uuid),public.claim_online_payment(),public.fail_online_payment(uuid,uuid,text),public.apply_online_payment(uuid,uuid,jsonb),public.notify_payment_webhook(uuid,text,text,text,text,text,text),public.configure_payment_cloud_worker(boolean),public.record_payment_worker_health(boolean)from public,anon,authenticated;
grant execute on function public.payment_connection_commit(uuid,uuid,uuid,text,text,boolean),public.payment_credential(uuid),public.claim_online_payment(),public.fail_online_payment(uuid,uuid,text),public.apply_online_payment(uuid,uuid,jsonb),public.notify_payment_webhook(uuid,text,text,text,text,text,text),public.configure_payment_cloud_worker(boolean),public.record_payment_worker_health(boolean)to service_role;

begin;
select no_plan();
insert into auth.users(id,email)values('e1000000-0000-0000-0000-000000000001','owner@today.test'),('e1000000-0000-0000-0000-000000000002','reader@today.test');
insert into public.tenants(id,name,slug)values('e2000000-0000-0000-0000-000000000001','Today tenant','today-data-test');
insert into public.properties(id,tenant_id,name,property_type,timezone)values
('e3000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Today hotel','hotel','Pacific/Kiritimati'),
('e3000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000001','Other hotel','hotel','UTC');
insert into public.tenant_memberships(tenant_id,user_id,role)values('e2000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001','owner'),('e2000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002','member');
insert into public.property_memberships(tenant_id,property_id,user_id)values('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002');
insert into public.guests(id,tenant_id,full_name)values('e4000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Today guest');
insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('e5000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','Standard',2,100);
insert into public.accommodation_units(tenant_id,property_id,type_id,name,housekeeping_status,active)values
('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000001','Clean','clean',true),
('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000001','Dirty','dirty',true),
('e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e5000000-0000-0000-0000-000000000001','Inactive','dirty',false);
insert into public.reservations(id,tenant_id,property_id,guest_id,check_in,check_out,status,total_amount,currency)
select ('e6000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e4000000-0000-0000-0000-000000000001',
 (now()at time zone'Pacific/Kiritimati')::date+case n when 1 then 0 when 2 then -2 when 3 then -1 when 4 then -1 when 5 then 2 when 6 then -3 else 0 end,
 (now()at time zone'Pacific/Kiritimati')::date+case n when 1 then 1 when 2 then 0 when 3 then 0 when 4 then 0 when 5 then 3 when 6 then -1 else 1 end,
 case n when 3 then'checked_in'when 4 then'checked_out'when 6 then'checked_in'when 7 then'cancelled'when 8 then'no_show'else'confirmed'end,100,'INR'
from generate_series(1,8)n;
insert into public.unit_holds(tenant_id,property_id,unit_id,reservation_id,kind,during)select r.tenant_id,r.property_id,u.id,r.id,'reservation',daterange(r.check_in,r.check_out,'[)')from public.reservations r join public.accommodation_units u on u.property_id=r.property_id and u.name='Clean'where r.id='e6000000-0000-0000-0000-000000000001';
insert into public.unit_holds(tenant_id,property_id,unit_id,reservation_id,kind,during)select r.tenant_id,r.property_id,u.id,r.id,'reservation',daterange(r.check_in,r.check_out,'[)')from public.reservations r join public.accommodation_units u on u.property_id=r.property_id and u.name='Clean'where r.id='e6000000-0000-0000-0000-000000000003';
insert into public.guest_documents(tenant_id,property_id,reservation_id,guest_id,doc_type,storage_path,mime_type,size_bytes,status)
select 'e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001',('e6000000-0000-0000-0000-'||lpad(case when n=3 then'5'else'1'end,12,'0'))::uuid,'e4000000-0000-0000-0000-000000000001','id_proof','today-test-'||n,'image/png',1,case n when 1 then'uploaded'when 2 then'clean'when 3 then'image_ready'else'rejected'end from generate_series(1,4)n;
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,display_phone,status,credentials_ref)values('e7000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','today-test-sender','today-test-waba','synthetic','active','test-not-used');
insert into public.conversations(id,tenant_id,property_id,connection_id,wa_contact_id,status)
select ('e8000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e7000000-0000-0000-0000-000000000001','synthetic-'||n,case when n=3 then'closed'else'open'end from generate_series(1,3)n;
insert into public.messages(tenant_id,property_id,conversation_id,direction,body,status,created_at)
select 'e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001',id,'in','Guest message','received',now()-interval'2 hours'from public.conversations where property_id='e3000000-0000-0000-0000-000000000001';
insert into public.messages(tenant_id,property_id,conversation_id,direction,body,status,created_at)
select 'e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001',id,'out','Reply',case when wa_contact_id='synthetic-1'then'failed'else'sent'end,now()-interval'1 hour'from public.conversations where property_id='e3000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is(public.hotel_today('e3000000-0000-0000-0000-000000000001')->>'day',((now()at time zone'Pacific/Kiritimati')::date)::text,'uses the hotel date, including UTC+14');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{work,counts,arrivals}')::int,1,'only pending arrivals still within stay dates');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{work,counts,departures}')::int,2,'includes overdue departures, excludes already checked-out stays');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{work,counts,documents}')::int,2,'document queue counts stays, not individual files');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{work,counts,inbox}')::int,1,'failed replies remain unanswered; successful and closed chats are excluded');
select is(public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{work,queue}','arrivals','default shows an actionable queue');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{work,rows,0,room_occupied}')::boolean,true,'a clean room is not ready while the previous guest is still checked in');
select is(public.hotel_today('e3000000-0000-0000-0000-000000000001','{"queue":"inbox"}')#>>'{work,rows,0,id}','e8000000-0000-0000-0000-000000000001','unanswered row matches the count');
select is(jsonb_array_length(public.hotel_today('e3000000-0000-0000-0000-000000000001','{"queue":"departures"}')#>'{work,rows}'),2,'departure rows match remaining work');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')->>'units')::int,2,'inactive rooms excluded');
select is(jsonb_array_length(public.hotel_today('e3000000-0000-0000-0000-000000000001')->'rooms_to_clean'),1,'only active rooms needing care');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{tonight,booked}')::int,1,'booked rooms use active holds');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000002')#>>'{work,total}')::int,0,'does not mix another property’s work');
select is(public.hotel_today('e3000000-0000-0000-0000-000000000001','{"queue":"bogus","page":"bad"}')#>>'{work,queue}','arrivals','invalid filters normalize safely');
select set_config('request.jwt.claims','{"sub":"e1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select ok(public.hotel_today('e3000000-0000-0000-0000-000000000001')#>'{work,counts,arrivals}'='null'::jsonb,'role without reservations sees no guest counts');
select ok(public.hotel_today('e3000000-0000-0000-0000-000000000001')#>'{work,counts,documents}'='null'::jsonb,'document count requires review access');
select ok(public.hotel_today('e3000000-0000-0000-0000-000000000001')#>'{work,counts,inbox}'='null'::jsonb,'inbox count requires WhatsApp access');
select is(jsonb_array_length(public.hotel_today('e3000000-0000-0000-0000-000000000001','{"queue":"documents"}')#>'{work,rows}'),0,'requesting hidden queue cannot disclose guest rows');
select ok(not(public.hotel_today('e3000000-0000-0000-0000-000000000001')?'collections'),'financial totals remain permission scoped');
select throws_ok($$select public.hotel_today('e3000000-0000-0000-0000-000000000002')$$,'42501',null,'cannot read an unassigned hotel');
reset role;
insert into public.roles(id,tenant_id,key,name)values('e9000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','today_reader','Reservation reader');
insert into public.role_permissions(role_id,permission_key)values('e9000000-0000-0000-0000-000000000001','reservations.read');
insert into public.user_roles(user_id,property_id,role_id)values('e1000000-0000-0000-0000-000000000002','e3000000-0000-0000-0000-000000000001','e9000000-0000-0000-0000-000000000001');
set local role authenticated;
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{work,counts,arrivals}')::int,1,'reservation reader sees permitted work');
select is((public.hotel_today('e3000000-0000-0000-0000-000000000001')#>>'{work,can_frontdesk}')::boolean,false,'read-only role cannot check guests in or out');
select ok(public.hotel_today('e3000000-0000-0000-0000-000000000001')#>'{work,counts,documents}'='null'::jsonb,'reservation access alone does not expose document-review counts');
select ok(public.hotel_today('e3000000-0000-0000-0000-000000000001','{"queue":"departures"}')#>'{work,rows,0,finance}'='null'::jsonb,'reservation access alone does not expose checkout finances');
reset role;
set local role anon;
select throws_ok($$select public.hotel_today('e3000000-0000-0000-0000-000000000001')$$,'42501',null,'anonymous caller cannot inspect Today');
select *from finish();
rollback;

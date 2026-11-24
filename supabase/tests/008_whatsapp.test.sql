begin;
select plan(29);

insert into auth.users (id, email) values
  ('91000000-0000-0000-0000-000000000002', 'clerk@t8.test'), ('91000000-0000-0000-0000-000000000003', 'hk@t8.test');
insert into public.tenants (id, name, slug) values ('92000000-0000-0000-0000-000000000001', 'Tenant 8', 'tenant-8');
insert into public.properties (id, tenant_id, name, property_type) values
  ('93000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000001', 'Prop 8', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role) values
  ('92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000002', 'member'),
  ('92000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000003', 'member');
insert into public.property_memberships (property_id, tenant_id, user_id)
select '93000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000001', u
from (values ('91000000-0000-0000-0000-000000000002'::uuid), ('91000000-0000-0000-0000-000000000003')) v(u);
insert into public.user_roles (property_id, user_id, role_id)
select '93000000-0000-0000-0000-000000000001', v.u, r.id
from (values ('91000000-0000-0000-0000-000000000002'::uuid, 'front_desk'), ('91000000-0000-0000-0000-000000000003', 'housekeeping')) v(u, k)
join public.roles r on r.key = v.k and r.tenant_id is null;
insert into public.whatsapp_connections (tenant_id, property_id, phone_number_id, waba_id, credentials_ref) values
  ('92000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-000000000001', '1001', 'waba-1', 'vault:wa-prop8');
insert into public.message_templates (tenant_id, property_id, name, status, body) values
  ('92000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-000000000001', 'checkin_reminder', 'approved', 'Your check-in is tomorrow'),
  ('92000000-0000-0000-0000-000000000001', '93000000-0000-0000-0000-000000000001', 'draft_promo', 'pending', 'Big sale');

-- webhook ingestion (service_role)
set local role service_role;
select lives_ok($$select public.ingest_whatsapp_inbound('1001','msg:m1','9199','Asha','m1','text','Hi, need towels','{}'::jsonb)$$, 'inbound message ingested');
select is(public.ingest_whatsapp_inbound('1001','msg:m1','9199','Asha','m1','text','Hi, need towels','{}'::jsonb), null, 'duplicate webhook delivery ignored');
select is(public.ingest_whatsapp_inbound('9999','msg:zz','1','x','zz','text','hi','{}'::jsonb), null, 'unknown phone number ignored');
select lives_ok($$select public.ingest_whatsapp_inbound('1001','msg:m1-retry','9199','Asha','m1','text','Hi, need towels','{}'::jsonb)$$, 'same wamid under a new event key');
select is((select count(*)::int from public.messages where property_id='93000000-0000-0000-0000-000000000001'and wa_message_id='m1'), 1, 'message deduplicated by wamid');

-- staff
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"91000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select is((select count(*)::int from public.conversations), 1, 'front desk sees the conversation');
select lives_ok($$select public.send_whatsapp_message((select id from public.conversations), 'Sure, on the way')$$, 'reply inside the 24h window');
select throws_ok($$select public.send_whatsapp_message((select id from public.conversations), null, (select id from public.message_templates where name='draft_promo'))$$, '22023', null, 'unapproved template rejected');

select set_config('request.jwt.claims', '{"sub":"91000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is_empty($$select 1 from public.conversations$$, 'housekeeper cannot see conversations');
select throws_ok($$select public.send_whatsapp_message((select id from public.conversations), 'hi')$$, '42501', null, 'housekeeper cannot send');

-- 24h window
reset role;
update public.conversations set last_inbound_at = now() - interval '2 days';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"91000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok($$select public.send_whatsapp_message((select id from public.conversations), 'Are you there?')$$, '22023', null, 'free text outside window rejected');
select lives_ok($$select public.send_whatsapp_message((select id from public.conversations), null, (select id from public.message_templates where name='checkin_reminder'))$$, 'approved template outside window');

-- opt-out / opt-in
reset role; set local role service_role;
do $$ begin perform public.ingest_whatsapp_inbound('1001','msg:m2','9199','Asha','m2','text','STOP','{}'::jsonb); end $$;
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"91000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select throws_ok($$select public.send_whatsapp_message((select id from public.conversations), null, (select id from public.message_templates where name='checkin_reminder'))$$, '22023', null, 'opted-out contact cannot be messaged');
reset role; set local role service_role;
do $$ begin perform public.ingest_whatsapp_inbound('1001','msg:m3','9199','Asha','m3','text','START','{}'::jsonb); end $$;
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"91000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok($$select public.send_whatsapp_message((select id from public.conversations), 'Anything else?')$$, 'opt-in restores messaging');

-- worker: isolate this fixture from existing local synthetic hotels (rolled back below).
reset role;
update public.messages set next_attempt_at=now()+interval '1 day'where property_id<>'93000000-0000-0000-0000-000000000001'and status='queued';
set local role service_role;
select is((select count(*)::int from public.claim_outbound_messages(10)), 3, 'worker claims all queued messages');
select is((select count(*)::int from public.claim_outbound_messages(10)), 0, 'claimed messages are not handed out twice');
do $$ begin perform public.complete_outbound_message((select id from public.messages where body = 'Sure, on the way'), null, false, 'timeout'); end $$;
select is((select status from public.messages where body = 'Sure, on the way'), 'queued', 'failed send is re-queued');
select ok((select next_attempt_at > now() from public.messages where body = 'Sure, on the way'), 'with backoff');
update public.messages set attempts = 5 where body = 'Your check-in is tomorrow';
do $$ begin perform public.complete_outbound_message((select id from public.messages where body = 'Your check-in is tomorrow'), null, false, 'rejected'); end $$;
select is((select status from public.messages where body = 'Your check-in is tomorrow'), 'failed', 'dead-lettered after max attempts');
do $$ begin perform public.complete_outbound_message((select id from public.messages where body = 'Anything else?'), 'wamid.OUT3', true, null); end $$;
select public.ingest_whatsapp_status('1001', 'st:OUT3:delivered', 'wamid.OUT3', 'delivered');
select is((select status from public.messages where body = 'Anything else?'), 'delivered', 'delivery status applied');
select public.ingest_whatsapp_status('1001', 'st:OUT3:sent', 'wamid.OUT3', 'sent');
select is((select status from public.messages where body = 'Anything else?'), 'delivered', 'out-of-order status does not go backwards');

-- status that races ahead of the worker is replayed on completion
update public.messages set next_attempt_at = now() where body = 'Sure, on the way';
select is((select count(*)::int from public.claim_outbound_messages(10)), 1, 're-queued message is claimed again');
do $$ begin
  perform public.ingest_whatsapp_status('1001', 'st:OUT1:read', 'wamid.OUT1', 'read');
  perform public.complete_outbound_message((select id from public.messages where body = 'Sure, on the way'), 'wamid.OUT1', true, null);
end $$;
select is((select status from public.messages where body = 'Sure, on the way'), 'read', 'early status replayed after completion');

-- inbox actions and privilege boundaries
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"91000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select lives_ok($$select public.claim_conversation((select id from public.conversations))$$, 'claim conversation');
select is((select assigned_to from public.conversations), '91000000-0000-0000-0000-000000000002'::uuid, 'assigned to claimer');
select lives_ok($$select public.set_conversation_handoff((select id from public.conversations), true)$$, 'human handoff');
select is((select human_handoff from public.conversations), true, 'handoff flag set');
select throws_ok($$select public.ingest_whatsapp_inbound('1001','x','1','n','mx','text','hi','{}'::jsonb)$$, '42501', null, 'staff cannot call webhook ingestion');
select throws_ok($$select public.claim_outbound_messages(5)$$, '42501', null, 'staff cannot drain the outbound queue');

select * from finish();
rollback;

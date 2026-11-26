begin;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id,email)values('f1320000-0000-0000-0000-000000000001','control-owner@test.invalid'),('f1320000-0000-0000-0000-000000000002','control-stranger@test.invalid');
insert into public.tenants(id,name,slug)values('f1321000-0000-0000-0000-000000000001','Control tenant','control-tenant-132');
insert into public.tenant_memberships(tenant_id,user_id,role)values('f1321000-0000-0000-0000-000000000001','f1320000-0000-0000-0000-000000000001','owner');
insert into public.properties(id,tenant_id,name,property_type)values('f1322000-0000-0000-0000-000000000001','f1321000-0000-0000-0000-000000000001','Control Hotel','hotel'),('f1322000-0000-0000-0000-000000000002','f1321000-0000-0000-0000-000000000001','Other Hotel','hotel');
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,credentials_ref)values('f1323000-0000-0000-0000-000000000001','f1321000-0000-0000-0000-000000000001','f1322000-0000-0000-0000-000000000001','13200000001','13200000002','synthetic'),('f1323000-0000-0000-0000-000000000002','f1321000-0000-0000-0000-000000000001','f1322000-0000-0000-0000-000000000002','13200000003','13200000004','synthetic');
insert into public.conversations(tenant_id,property_id,connection_id,wa_contact_id,contact_name,human_handoff)
 select 'f1321000-0000-0000-0000-000000000001','f1322000-0000-0000-0000-000000000001','f1323000-0000-0000-0000-000000000001','91900000013'||n,'Paused Guest '||n,true from generate_series(1,6)n;
insert into public.conversations(tenant_id,property_id,connection_id,wa_contact_id,contact_name,human_handoff,status)values
 ('f1321000-0000-0000-0000-000000000001','f1322000-0000-0000-0000-000000000001','f1323000-0000-0000-0000-000000000001','919000000140','Closed Guest',true,'closed'),
 ('f1321000-0000-0000-0000-000000000001','f1322000-0000-0000-0000-000000000002','f1323000-0000-0000-0000-000000000002','919000000141','Other Hotel Guest',true,'open');
set local role anon;
select throws_ok($$select public.whatsapp_control_status('f1322000-0000-0000-0000-000000000001')$$,'42501',null,'Anonymous callers cannot inspect paused guests');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"f1320000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.whatsapp_control_status('f1322000-0000-0000-0000-000000000001')$$,'42501',null,'Another account cannot inspect this hotel');
select set_config('request.jwt.claims','{"sub":"f1320000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.whatsapp_control_status('f1322000-0000-0000-0000-000000000001')->>'paused_count')::int,6,'Count excludes resolved chats and another hotel');
select is(jsonb_array_length(public.whatsapp_control_status('f1322000-0000-0000-0000-000000000001')->'paused_chats'),5,'Guest list is bounded independently of the full count');
select is((public.whatsapp_control_status('f1322000-0000-0000-0000-000000000001')->>'blocked_count')::int,0,'No historical queued messages are mislabeled as currently blocked');
select ok(not exists(select 1 from jsonb_array_elements(public.whatsapp_control_status('f1322000-0000-0000-0000-000000000001')->'paused_chats')x where x->>'name'='Other Hotel Guest'),'Only this hotel’s guest names are exposed');
select is((select count(*)::int from public.conversations where property_id='f1322000-0000-0000-0000-000000000001'and human_handoff),7,'Reading setup never resumes paused conversations');
select *from finish();
rollback;

begin;
select no_plan();

insert into auth.users (id, email, email_confirmed_at) values
  ('b1000000-0000-0000-0000-000000000001', 'owner@advanced-team.test', now()), ('b1000000-0000-0000-0000-000000000002', 'admin@advanced-team.test', now()),
  ('b1000000-0000-0000-0000-000000000003', 'member@advanced-team.test', now()), ('b1000000-0000-0000-0000-000000000004', 'new@x.com', now()),
  ('b1000000-0000-0000-0000-000000000005', 'other@x.com', now()), ('b1000000-0000-0000-0000-000000000006', 'unconf@x.com', null),
  ('b1000000-0000-0000-0000-000000000007', 'exp@x.com', now()), ('b1000000-0000-0000-0000-000000000008', 'rev@x.com', now());
insert into public.tenants (id, name, slug) values
  ('b2000000-0000-0000-0000-000000000001', 'Tenant 10', 'advanced-team'), ('b2000000-0000-0000-0000-000000000002', 'Other Tenant', 'advanced-team-other');
insert into public.properties (id, tenant_id, name, property_type) values
  ('b3000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000001', 'Prop 10', 'hotel'),
  ('b3000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', 'Foreign Prop', 'hotel');
insert into public.tenant_memberships (tenant_id, user_id, role) values
  ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'owner'),
  ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000002', 'admin'),
  ('b2000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000003', 'member');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.team_workspace('b2000000-0000-0000-0000-000000000001')->>'total')::int,3,'directory lists all business members');
select ok((public.team_setup('b2000000-0000-0000-0000-000000000001')->>'can_owner')::boolean,'setup identifies owner-only controls');
select set_config('test.invite',public.team_action('b2000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','invite',null,null,'{"email":"New@X.com","business_role":"member","days":7,"grants":[{"property_id":"b3000000-0000-0000-0000-000000000001","role_key":"housekeeping"}]}')::text,true);
select is(public.team_action('b2000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000001','invite',null,null,'{"email":"New@X.com","business_role":"member","days":7,"grants":[{"property_id":"b3000000-0000-0000-0000-000000000001","role_key":"housekeeping"}]}')::text,current_setting('test.invite'),'invitation retry is idempotent');
select is((select expires_at from public.staff_invitations where id=current_setting('test.invite')::uuid),now()+interval '7 days','reviewed validity is applied');
select is((select email from public.staff_invitations where id=current_setting('test.invite')::uuid),'new@x.com','invited address is normalized');
select throws_ok($$select public.team_action('b2000000-0000-0000-0000-000000000001',gen_random_uuid(),'renew',current_setting('test.invite')::uuid,0,'{"days":14}')$$,'40001',null,'stale invitation changes rejected');
select lives_ok($$select public.team_action('b2000000-0000-0000-0000-000000000001',gen_random_uuid(),'renew',current_setting('test.invite')::uuid,(select version from public.staff_invitations where id=current_setting('test.invite')::uuid),'{"days":14}')$$,'pending invitation can be renewed');
select is((select expires_at from public.staff_invitations where id=current_setting('test.invite')::uuid),now()+interval '14 days','renewal extends from current time');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.invite_staff('b2000000-0000-0000-0000-000000000001','new-admin@test.invalid','admin')$$,'42501',null,'administrator cannot create another administrator');
select throws_ok($$select public.remove_staff('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000002')$$,'42501',null,'administrator cannot remove administrator access');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is(public.accept_staff_invitations(),1,'matching confirmed invitee accepts reviewed invitation');
select is(public.accept_staff_invitations(),0,'accepted invitation cannot be accepted twice');
select ok(private.has_permission('b3000000-0000-0000-0000-000000000001','tasks.write'),'invitation applies property task permissions');
select throws_ok($$select public.team_workspace('b2000000-0000-0000-0000-000000000001')$$,'42501',null,'ordinary staff cannot browse team administration');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((select count(*)::int from public.staff_events where invitation_id=current_setting('test.invite')::uuid and action='invitation_accepted'),1,'acceptance recorded once in audit history');
select is((public.team_member_detail('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000004')#>>'{access,0,property_name}'),'Prop 10','member access lists current business hotels');
select throws_ok($$select public.team_action('b2000000-0000-0000-0000-000000000001',gen_random_uuid(),'access','b1000000-0000-0000-0000-000000000004',0,'{"property_id":"b3000000-0000-0000-0000-000000000001","roles":["front_desk"],"reason":"Change duty"}')$$,'40001',null,'stale member changes rejected');
select lives_ok($$select public.team_action('b2000000-0000-0000-0000-000000000001',gen_random_uuid(),'access','b1000000-0000-0000-0000-000000000004',(select version from public.tenant_memberships where tenant_id='b2000000-0000-0000-0000-000000000001'and user_id='b1000000-0000-0000-0000-000000000004'),'{"property_id":"b3000000-0000-0000-0000-000000000001","roles":["front_desk","kitchen"],"reason":"Front desk and kitchen duty"}')$$,'reviewed property roles combine permissions');
select ok(exists(select 1 from jsonb_array_elements_text(public.team_member_detail('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000004')#>'{access,0,permissions}')p where p='orders.write'),'effective preview includes kitchen progress permission');
select is((select details->>'reason'from public.staff_events where target_user='b1000000-0000-0000-0000-000000000004'and action='property_access_changed'order by created_at desc,id desc limit 1),'Front desk and kitchen duty','access-change reason is audited');
select public.set_staff_access('b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000004',array['housekeeping']);
select set_config('test.task',public.create_task('b3000000-0000-0000-0000-000000000001','Prepare assigned work','general','normal','b1000000-0000-0000-0000-000000000004')::text,true);
select throws_ok($$select public.set_staff_access('b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000004',array['front_desk'])$$,'22023',null,'task-work permissions cannot disappear beneath active assignments');
select throws_ok($$select public.remove_staff('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000004')$$,'22023',null,'staff removal requires open work to be reassigned');
select is((public.team_member_detail('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000004')#>>'{access,0,tasks,0,title}'),'Prepare assigned work','access review includes direct work links');
select public.assign_task(current_setting('test.task')::uuid,null);
select lives_ok($$select public.set_staff_access('b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000004',array['front_desk'])$$,'permissions can change after work is reassigned');
select set_config('test.outgoing',public.invite_staff('b2000000-0000-0000-0000-000000000001','outgoing@test.invalid','member')::text,true);
select lives_ok($$select public.team_action('b2000000-0000-0000-0000-000000000001',gen_random_uuid(),'revoke',current_setting('test.outgoing')::uuid,(select version from public.staff_invitations where id=current_setting('test.outgoing')::uuid),'{"reason":"Invitation no longer required"}')$$,'reviewed revocation records reason');
select is((select details->>'reason'from public.staff_events where invitation_id=current_setting('test.outgoing')::uuid and action='invitation_revoked'),'Invitation no longer required','revocation reason is retained');
select throws_ok($$select public.revoke_staff_invitation(current_setting('test.invite')::uuid)$$,'22023',null,'accepted invitation cannot be revoked to remove membership');
select throws_ok($$select public.set_tenant_role('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','member')$$,'23514',null,'last-owner protection applies through business role RPC');
select throws_ok($$select public.team_workspace('b2000000-0000-0000-0000-000000000002')$$,'42501',null,'business administration scope cannot cross tenants');
select throws_ok($$select public.invite_staff('b2000000-0000-0000-0000-000000000001','member@advanced-team.test','member')$$,'22023',null,'existing members are managed through access rather than reinvited');
select lives_ok($$select public.team_action('b2000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000002','remove','b1000000-0000-0000-0000-000000000004',(select version from public.tenant_memberships where tenant_id='b2000000-0000-0000-0000-000000000001'and user_id='b1000000-0000-0000-0000-000000000004'),'{"reason":"Finished employment"}')$$,'reviewed removal revokes membership without deleting account');
select is((select count(*)::int from public.tenant_memberships where tenant_id='b2000000-0000-0000-0000-000000000001'and user_id='b1000000-0000-0000-0000-000000000004'),0,'removed member has no business membership');
reset role;
select is((select count(*)::int from auth.users where id='b1000000-0000-0000-0000-000000000004'),1,'removed person retains their account');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select ok(not private.has_property_access('b3000000-0000-0000-0000-000000000001'),'removed person loses hotel access');
select ok(not has_function_privilege('anon','public.team_action(uuid,uuid,text,uuid,integer,jsonb)','execute'),'anonymous team mutations revoked');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select is((public.team_invitation_detail('b2000000-0000-0000-0000-000000000001',current_setting('test.invite')::uuid)->>'member_exists')::boolean,false,'accepted invitation records removal without linking to a missing membership');
select set_config('test.admin_invite',public.invite_staff('b2000000-0000-0000-0000-000000000001','other@x.com','admin')::text,true);
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select is(public.accept_staff_invitations(),1,'owner-issued administrator invite is accepted');
select set_config('test.delegated_invite',public.invite_staff('b2000000-0000-0000-0000-000000000001','delegated@test.invalid','member')::text,true);
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.set_tenant_role('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000005','member');
select is((select status from public.staff_invitations where id=current_setting('test.delegated_invite')::uuid),'revoked','administrator demotion revokes their pending delegations');
select set_config('test.expired_admin',public.invite_staff('b2000000-0000-0000-0000-000000000001','expired-admin@test.invalid','admin')::text,true);
reset role;
update public.staff_invitations set expires_at=now()-interval '1 day'where id=current_setting('test.expired_admin')::uuid;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.team_action('b2000000-0000-0000-0000-000000000001',gen_random_uuid(),'invite',null,null,'{"email":"expired-admin@test.invalid","business_role":"member","days":7,"grants":[]}')$$,'42501',null,'administrator cannot replace an expired administrator invitation');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select public.invite_staff('b2000000-0000-0000-0000-000000000001','page-invite-'||i||'@test.invalid','member')from generate_series(1,23)i;
select is((public.team_workspace('b2000000-0000-0000-0000-000000000001','{"mode":"invitations","q":"page-invite-","page":2}')->>'total')::int,23,'invitation count includes all matching records');
select is(jsonb_array_length(public.team_workspace('b2000000-0000-0000-0000-000000000001','{"mode":"invitations","q":"page-invite-","page":2}')->'rows'),3,'second invitation page returns remaining records');
select public.set_staff_access('b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000005',array['front_desk']);
reset role;
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,credentials_ref)values('b7000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000001','b3000000-0000-0000-0000-000000000001','team-test-only','test','test-not-used');
insert into public.conversations(id,tenant_id,property_id,connection_id,wa_contact_id,assigned_to)values('b7000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-000000000001','b3000000-0000-0000-0000-000000000001','b7000000-0000-0000-0000-000000000001','team-test-contact','b1000000-0000-0000-0000-000000000005');
set local role authenticated;
select throws_ok($$select public.set_staff_access('b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000005',array['housekeeping'])$$,'22023',null,'open inbox assignments protect needed inbox access');
select public.close_conversation('b7000000-0000-0000-0000-000000000002');
select public.set_staff_access('b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000005',array['housekeeping']);
select lives_ok($$select public.inbox_manage('b7000000-0000-0000-0000-000000000002',(select version from public.conversations where id='b7000000-0000-0000-0000-000000000002'),'reopen')$$,'closed inbox work can reopen after role change');
select is((select assigned_to from public.conversations where id='b7000000-0000-0000-0000-000000000002'),null::uuid,'reopened conversation is released from a now-ineligible assignee');
select set_config('test.done_task',public.create_task('b3000000-0000-0000-0000-000000000001','Completed historic work','general','normal','b1000000-0000-0000-0000-000000000005')::text,true);
select public.set_task_status(current_setting('test.done_task')::uuid,'done');
select public.set_staff_access('b3000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000005',array['front_desk']);
select lives_ok($$select public.set_task_status(current_setting('test.done_task')::uuid,'open')$$,'historic tasks can reopen after role change');
select is((select assignee_id from public.tasks where id=current_setting('test.done_task')::uuid),null::uuid,'reopened task is released from a now-ineligible worker');
select * from finish();rollback;

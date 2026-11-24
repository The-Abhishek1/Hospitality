begin;
select no_plan();
insert into auth.users(id,email,email_confirmed_at)values
 ('b1000000-0000-0000-0000-000000000001','owner@team-email.test',now()),
 ('b1000000-0000-0000-0000-000000000002','admin@team-email.test',now()),
 ('b1000000-0000-0000-0000-000000000003','member@team-email.test',now()),
 ('b1000000-0000-0000-0000-000000000004','new@team-email.test',now()),
 ('b1000000-0000-0000-0000-000000000005','foreign@team-email.test',now());
insert into public.tenants(id,name,slug)values('b2000000-0000-0000-0000-000000000001','Email hotel business','email-team-test'),('b2000000-0000-0000-0000-000000000002','Foreign business','email-team-foreign');
insert into public.properties(id,tenant_id,name,property_type)values('b3000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000001','Selected hotel','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values
 ('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','owner'),
 ('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000002','admin'),
 ('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000003','member'),
 ('b2000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000005','owner');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select set_config('test.invite',public.invite_staff('b2000000-0000-0000-0000-000000000001','new@team-email.test','member','[{"property_id":"b3000000-0000-0000-0000-000000000001","role_key":"front_desk"}]')::text,true);
select set_config('test.admin_invite',public.invite_staff('b2000000-0000-0000-0000-000000000001','newadmin@team-email.test','admin')::text,true);
select set_config('test.claim',public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.invite')::uuid,'b6000000-0000-0000-0000-000000000001',1)::text,true);
select ok((current_setting('test.claim')::jsonb->>'send')::boolean,'owner claims one email attempt');
select is(current_setting('test.claim')::jsonb#>>'{context,email}','new@team-email.test','recipient comes from stored invitation');
select is(jsonb_array_length(current_setting('test.claim')::jsonb#>'{context,hotels}'),1,'email only describes assigned hotels');
select is(current_setting('test.claim')::jsonb#>>'{context,hotels,0,name}','Selected hotel','email includes selected hotel name');
select is(current_setting('test.claim')::jsonb#>>'{context,business}','Email hotel business','email includes correct business');
select is((select status from public.staff_invitations where id=current_setting('test.invite')::uuid),'pending','email claim never grants membership');
select is((public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.invite')::uuid,'b6000000-0000-0000-0000-000000000001',1)->>'send')::boolean,false,'duplicate submission never sends a second email');
select is((select count(*)::integer from public.staff_invitation_emails),1,'duplicate request creates only one delivery');
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.admin_invite')::uuid,'b6000000-0000-0000-0000-000000000001',1)$$,'22023',null,'request cannot target a different invitation');
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.invite')::uuid,gen_random_uuid(),1)$$,'22023',null,'new request observes resend cooldown');
select throws_ok($$select public.team_invitation_email_finish((current_setting('test.claim')::jsonb->>'delivery_id')::uuid,'sent','fake-provider-id',null)$$,'42501',null,'browser cannot forge a provider result');
select throws_ok($$update public.staff_invitation_emails set status='sent'$$,'42501',null,'browser cannot write email records directly');
set local role service_role;
select lives_ok($$select public.team_invitation_email_finish((current_setting('test.claim')::jsonb->>'delivery_id')::uuid,'failed',null,'sender')$$,'backend records a failed email');
select lives_ok($$select public.team_invitation_email_finish((current_setting('test.claim')::jsonb->>'delivery_id')::uuid,'sent','late-provider-id',null)$$,'repeated completion is harmless');
reset role;
select is((select status from public.staff_invitation_emails where id=(current_setting('test.claim')::jsonb->>'delivery_id')::uuid),'failed','late completion cannot overwrite recorded result');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000003","role":"authenticated"}',true);
select is((select count(*)::integer from public.staff_invitation_email_latest),0,'ordinary teammate cannot read email status');
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.invite')::uuid,gen_random_uuid(),1)$$,'42501',null,'ordinary teammate cannot send invitations');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000005","role":"authenticated"}',true);
select is((select count(*)::integer from public.staff_invitation_email_latest),0,'another business cannot read email status');
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000002',current_setting('test.invite')::uuid,gen_random_uuid(),1)$$,'P0002',null,'foreign invitation cannot be sent under another business');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.admin_invite')::uuid,gen_random_uuid(),1)$$,'42501',null,'administrator cannot email an administrator invitation');
reset role;
update public.staff_invitation_emails set created_at=now()-interval '3 minutes';
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000002","role":"authenticated"}',true);
select set_config('test.retry',public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.invite')::uuid,'b6000000-0000-0000-0000-000000000002',1)::text,true);
select ok((current_setting('test.retry')::jsonb->>'send')::boolean,'administrator can resend property staff invitation after cooldown');
set local role service_role;
select lives_ok($$select public.team_invitation_email_finish((current_setting('test.retry')::jsonb->>'delivery_id')::uuid,'sent','provider-email-123',null)$$,'provider acceptance recorded');
reset role;
select is((select status from public.staff_invitation_email_latest where invitation_id=current_setting('test.invite')::uuid),'sent','directory shows latest email result');
select is((select count(*)::integer from public.staff_invitation_email_latest where invitation_id=current_setting('test.invite')::uuid),1,'status view contains only one row per invitation');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.invite')::uuid,gen_random_uuid(),99)$$,'40001',null,'stale invitation version cannot send');
reset role;
update public.staff_invitations set expires_at=now()-interval '1 minute'where id=current_setting('test.admin_invite')::uuid;
set local role authenticated;
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.admin_invite')::uuid,gen_random_uuid(),(select version from public.staff_invitations where id=current_setting('test.admin_invite')::uuid))$$,'22023',null,'expired invitations cannot be emailed');
reset role;
update public.staff_invitations set expires_at=now()+interval '1 day',status='revoked'where id=current_setting('test.admin_invite')::uuid;
set local role authenticated;
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.admin_invite')::uuid,gen_random_uuid(),(select version from public.staff_invitations where id=current_setting('test.admin_invite')::uuid))$$,'22023',null,'revoked invitations cannot be emailed');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000004","role":"authenticated"}',true);
select is(public.accept_staff_invitations(),1,'email outcomes do not replace matching confirmed-account acceptance');
select ok(private.has_permission('b3000000-0000-0000-0000-000000000001','reservations.write'),'accepted teammate gets reviewed property roles');
select set_config('request.jwt.claims','{"sub":"b1000000-0000-0000-0000-000000000001","role":"authenticated"}',true);
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.invite')::uuid,gen_random_uuid(),(select version from public.staff_invitations where id=current_setting('test.invite')::uuid))$$,'22023',null,'accepted invitation cannot be resent');
select set_config('test.quota',public.invite_staff('b2000000-0000-0000-0000-000000000001','quota@team-email.test','member')::text,true);
reset role;
insert into public.staff_invitation_emails(tenant_id,invitation_id,request_id,invitation_version,context,status,created_at)
 select 'b2000000-0000-0000-0000-000000000001',current_setting('test.quota')::uuid,gen_random_uuid(),1,'{}','failed',now()-interval '3 minutes'from generate_series(1,10);
set local role authenticated;
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.quota')::uuid,gen_random_uuid(),1)$$,'22023',null,'per invitation daily limit is enforced');
select ok(not has_function_privilege('anon','public.team_invitation_email_start(uuid,uuid,uuid,integer)','execute'),'anonymous cannot request invitation email');
select ok(not has_function_privilege('authenticated','public.team_invitation_email_finish(uuid,text,text,text)','execute'),'only backend can record provider acceptance');
select set_config('test.hourly',public.invite_staff('b2000000-0000-0000-0000-000000000001','hourly@team-email.test','member')::text,true);
reset role;
insert into public.staff_invitation_emails(tenant_id,invitation_id,request_id,invitation_version,context,status,created_at)
 select 'b2000000-0000-0000-0000-000000000001',current_setting('test.quota')::uuid,gen_random_uuid(),1,'{}','failed',now()-interval '3 minutes'from generate_series(1,88);
set local role authenticated;
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.hourly')::uuid,gen_random_uuid(),1)$$,'22023',null,'business hourly email limit is enforced across invitations');
reset role;
update public.staff_invitations set invited_by='b1000000-0000-0000-0000-000000000003'where id=current_setting('test.hourly')::uuid;
set local role authenticated;
select throws_ok($$select public.team_invitation_email_start('b2000000-0000-0000-0000-000000000001',current_setting('test.hourly')::uuid,gen_random_uuid(),(select version from public.staff_invitations where id=current_setting('test.hourly')::uuid))$$,'22023',null,'stale delegation from a non-administrator cannot be emailed');
set local role service_role;
select throws_ok($$select public.team_invitation_email_finish((current_setting('test.claim')::jsonb->>'delivery_id')::uuid,'sent',null,null)$$,'22023',null,'provider acceptance requires a provider email ID');
select * from finish();
rollback;

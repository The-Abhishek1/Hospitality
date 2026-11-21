"""Local staff/invitation/assignment races; uses temporary UUID-scoped records."""
import concurrent.futures
import json
import subprocess
import threading
import uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner1,owner2,worker,new_user,tenant,prop=[str(uuid.uuid4())for _ in range(6)]

def sql(query,required=True):
    r=subprocess.run(['psql',DB,'-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',query],capture_output=True,text=True,timeout=25)
    if required and r.returncode:raise RuntimeError(r.stderr)
    return r

def actor(user,query):
    return "begin;set local lock_timeout='5s';set local role authenticated;select set_config('request.jwt.claims','"+json.dumps({'sub':user,'role':'authenticated'})+"',true);"+query+";commit;"

def race(queries):
    barrier=threading.Barrier(len(queries))
    def run(query):
        barrier.wait();return sql(query,False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries))as pool:return list(pool.map(run,queries))

try:
    sql(f"""begin;
    insert into auth.users(id,email,email_confirmed_at)values('{owner1}','team-race-{owner1}@test.invalid',now()),('{owner2}','team-race-{owner2}@test.invalid',now()),('{worker}','team-race-{worker}@test.invalid',now()),('{new_user}','team-race-{new_user}@test.invalid',now());
    insert into public.tenants(id,name,slug)values('{tenant}','Team test','team-race-{tenant}');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner1}','owner'),('{tenant}','{owner2}','owner'),('{tenant}','{worker}','member');
    insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Team test','hotel');
    insert into public.property_memberships(tenant_id,property_id,user_id)values('{tenant}','{prop}','{worker}');
    insert into public.user_roles(property_id,user_id,role_id)select '{prop}','{worker}',id from public.roles where key='housekeeping'and tenant_id is null;commit;""")
    for _ in range(4):
        current_owner=sql(f"select user_id from public.tenant_memberships where tenant_id='{tenant}'and role='owner'limit 1").stdout.strip()
        sql(actor(current_owner,f"select public.set_tenant_role('{tenant}','{owner1}','owner');select public.set_tenant_role('{tenant}','{owner2}','owner')"))
        results=race([actor(u,f"select public.set_tenant_role('{tenant}','{u}','member')")for u in [owner1,owner2]])
        assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
        assert all(not r.returncode or '23514'in r.stderr for r in results),str([r.stderr for r in results])
        assert sql(f"select count(*)from public.tenant_memberships where tenant_id='{tenant}'and role='owner'").stdout.strip()=='1'
    owner=sql(f"select user_id from public.tenant_memberships where tenant_id='{tenant}'and role='owner'").stdout.strip()
    print('4 concurrent owner-demotion races: the business always retains one owner.')
    grants=json.dumps([{'property_id':prop,'role_key':'housekeeping'}])
    for _ in range(8):
        invite=sql(actor(owner,f"select public.invite_staff('{tenant}','team-race-{new_user}@test.invalid','member','{grants}')")).stdout.splitlines()[-1]
        results=race([actor(new_user,'select public.accept_staff_invitations()'),actor(owner,f"select public.revoke_staff_invitation('{invite}')")])
        assert results[0].returncode==0,results[0].stderr
        assert results[1].returncode==0 or '22023'in results[1].stderr,results[1].stderr
        state=sql(f"select status||'|'||exists(select 1 from public.tenant_memberships where tenant_id='{tenant}'and user_id='{new_user}')from public.staff_invitations where id='{invite}'").stdout.strip()
        assert state in ('accepted|true','revoked|false'),state
        if state=='accepted|true':sql(actor(owner,f"select public.remove_staff('{tenant}','{new_user}')"))
    print('8 acceptance-versus-revocation races: membership matches the final invitation state.')
    for i in range(8):
        sql(actor(owner,f"select public.set_staff_access('{prop}','{worker}',array['housekeeping'])"))
        task=sql(actor(owner,f"select public.create_task('{prop}','Claim test {i}')")).stdout.splitlines()[-1]
        results=race([actor(worker,f"select public.claim_task('{task}')"),actor(owner,f"select public.set_staff_access('{prop}','{worker}','{{}}')")])
        assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
        assert all(not r.returncode or any(code in r.stderr for code in ['22023','42501'])for r in results),str([r.stderr for r in results])
        assert sql(f"select not exists(select 1 from public.tasks where id='{task}'and assignee_id='{worker}'and not private.service_task_eligible('{prop}','{worker}'))").stdout.strip()=='t'
        sql(actor(owner,f"select public.assign_task('{task}',null)"))
    print('8 claim-versus-access-removal races: no active task is stranded on an ineligible worker.')
    for i in range(4):
        sql(actor(owner,f"select public.set_staff_access('{prop}','{worker}',array['housekeeping'])"))
        details=json.dumps({'name':f'Service assignment {i}','category':'Amenities','priority':'normal','kind':'housekeeping','assignee':worker,'active':True})
        results=race([actor(owner,f"select public.service_catalog_save('{prop}','{uuid.uuid4()}',null,null,'{details}')"),actor(owner,f"select public.set_staff_access('{prop}','{worker}','{{}}')")])
        assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
        assert all(not r.returncode or '22023'in r.stderr for r in results),str([r.stderr for r in results])
        assert sql(f"select not exists(select 1 from public.service_routing_rules where tenant_id='{tenant}'and default_assignee_id='{worker}'and not private.service_task_eligible('{prop}','{worker}'))").stdout.strip()=='t'
        sql(f"update public.service_routing_rules set default_assignee_id=null where tenant_id='{tenant}'")
    print('4 default-service-assignment versus access-removal races: no stale routing or lock inversion.')
    details=json.dumps({'email':f'team-race-{new_user}@test.invalid','business_role':'member','days':7,'grants':[{'property_id':prop,'role_key':'housekeeping'}]})
    command=actor(owner,f"select public.team_action('{tenant}','{uuid.uuid4()}','invite',null,null,'{details}')")
    results=race([command]*8);assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
    assert sql(f"select count(*)from public.staff_invitations where tenant_id='{tenant}'and status='pending'").stdout.strip()=='1'
    print('8 identical reviewed invitation submissions: one pending invitation.')
finally:
    sql(f"""begin;
    delete from public.tasks where tenant_id='{tenant}';
    delete from public.tenants where id='{tenant}';
    delete from auth.users where id in('{owner1}','{owner2}','{worker}','{new_user}');commit;""")
    assert sql(f"select count(*)from public.tenants where id='{tenant}'").stdout.strip()=='0'
    print('Isolated team-test fixtures removed.')

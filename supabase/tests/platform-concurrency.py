"""Concurrent platform commands and owner hotel creation; isolated disposable accounts."""
import concurrent.futures
import json
import subprocess
import threading
import uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
admin,owner,tenant=[str(uuid.uuid4())for _ in range(3)]
slug='platform-race-'+tenant

def sql(query,required=True):
    result=subprocess.run(['psql',DB,'-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',query],capture_output=True,text=True,timeout=25)
    if required and result.returncode:raise RuntimeError(result.stderr)
    return result

def transaction(user,query):
    claims=json.dumps({'sub':user,'role':'authenticated'})
    return f"begin;set local lock_timeout='5s';set local role authenticated;select set_config('request.jwt.claims','{claims}',true);{query};commit;"

def race(jobs):
    barrier=threading.Barrier(len(jobs))
    def run(job):
        barrier.wait();return sql(transaction(*job),False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs))as pool:return list(pool.map(run,jobs))

def command(action,details,version,request=None):
    details={'reason':'Isolated concurrency verification',**details}
    return f"select public.platform_manage('{tenant}',{version},'{request or uuid.uuid4()}','{action}','{json.dumps(details)}')"

def hotel():
    return {'name':'Race hotel','property_type':'hotel','timezone':'UTC','currency':'INR','country_code':'IN'}

try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{admin}','platform-admin-{admin}@test.invalid'),('{owner}','platform-owner-{owner}@test.invalid');
    insert into public.platform_admins(user_id)values('{admin}');
    insert into public.tenants(id,name,slug)values('{tenant}','Platform concurrency','{slug}');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');
    insert into public.subscriptions(tenant_id,plan_id,status)select '{tenant}',id,'active'from public.plans where key='growth';commit;""")
    create=command('add_hotel',hotel(),1,str(uuid.uuid4()))
    results=race([(admin,create)]*6)
    assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
    assert sql(f"select count(*)from public.properties where tenant_id='{tenant}'").stdout.strip()=='1'
    assert sql(f"select count(*)from public.platform_audit_logs where tenant_id='{tenant}'").stdout.strip()=='1'
    print('6 simultaneous retries create one hotel and one audit event.')
    results=race([(admin,command('add_hotel',hotel(),2)),(admin,command('plan',{'plan':'enterprise','confirmation':slug},2))])
    assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
    assert all(r.returncode==0 or '40001'in r.stderr for r in results),str([r.stderr for r in results])
    print('Competing administrator changes reject the stale version.')
    for _ in range(4):
        # Restore an exact two-hotel growth fixture between each race.
        sql(f"delete from public.properties where tenant_id='{tenant}';update public.subscriptions set plan_id=(select id from public.plans where key='growth')where tenant_id='{tenant}';insert into public.properties(tenant_id,name,property_type)values('{tenant}','Race one','hotel'),('{tenant}','Race two','hotel');")
        version=sql(f"select admin_version from public.tenants where id='{tenant}'").stdout.strip()
        create_owner=f"select public.create_property('{tenant}','{uuid.uuid4()}','Third race hotel','hotel','UTC','INR')"
        results=race([(admin,command('plan',{'plan':'starter','confirmation':slug},version)),(owner,create_owner)])
        assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
        assert all(r.returncode==0 or '53400'in r.stderr for r in results),str([r.stderr for r in results])
        assert sql(f"select count(*)<=(select (e.value#>>'{{}}')::integer from public.subscriptions s join public.plan_entitlements e on e.plan_id=s.plan_id and e.key='max_properties'where s.tenant_id='{tenant}')from public.properties where tenant_id='{tenant}'").stdout.strip()=='t'
    print('4 downgrade-versus-owner-creation races preserve the hotel cap.')
finally:
    sql(f"begin;delete from public.platform_audit_logs where actor_id='{admin}';delete from private.platform_commands where actor_id='{admin}';delete from public.tenants where id='{tenant}';delete from auth.users where id in('{admin}','{owner}');commit;")
    assert sql(f"select count(*)from public.tenants where id='{tenant}'").stdout.strip()=='0'
    print('Isolated platform fixtures removed.')

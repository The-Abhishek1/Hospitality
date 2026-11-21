"""Local-only task claim/checklist races. All UUID fixtures are removed afterward."""
import concurrent.futures
import json
import subprocess
import threading
import uuid

DB = 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner, hk1, hk2, tenant, prop, room_type, room = [str(uuid.uuid4()) for _ in range(7)]

def sql(query, required=True):
    r = subprocess.run(['psql', DB, '-XqAt', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose', '-c', query], capture_output=True, text=True, timeout=20)
    if required and r.returncode:
        raise RuntimeError(r.stderr)
    return r

def actor(user, query):
    return "begin;set local lock_timeout='5s';set local role authenticated;select set_config('request.jwt.claims','"+json.dumps({'sub': user, 'role': 'authenticated'})+"',true);"+query+";commit;"

def race(queries):
    barrier = threading.Barrier(len(queries))
    def run(query):
        barrier.wait()
        return sql(query, False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries)) as pool:
        return list(pool.map(run, queries))

try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{owner}','task-race-{owner}@test.invalid'),('{hk1}','task-race-{hk1}@test.invalid'),('{hk2}','task-race-{hk2}@test.invalid');
    insert into public.tenants(id,name,slug)values('{tenant}','Task test','task-race-{tenant}');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner'),('{tenant}','{hk1}','member'),('{tenant}','{hk2}','member');
    insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Task test','hotel');
    insert into public.property_memberships(tenant_id,property_id,user_id)values('{tenant}','{prop}','{hk1}'),('{tenant}','{prop}','{hk2}');
    insert into public.user_roles(property_id,user_id,role_id)select '{prop}',u,r.id from(values('{hk1}'::uuid),('{hk2}'::uuid))v(u)join public.roles r on r.key='housekeeping'and r.tenant_id is null;
    insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('{room_type}','{tenant}','{prop}','Test room',2,100);
    insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('{room}','{tenant}','{prop}','{room_type}','T1');commit;""")
    details=json.dumps({'title':'Clean test room','kind':'housekeeping','priority':'normal','unit':room,'checklist':['Final inspection']})
    create=actor(owner,f"select public.task_create_advanced('{prop}','{uuid.uuid4()}','{details}')")
    results=race([create]*8)
    assert all(r.returncode==0 for r in results), str([r.stderr for r in results])
    assert sql(f"select count(*)from public.tasks where property_id='{prop}'").stdout.strip()=='1'
    task=sql(f"select id from public.tasks where property_id='{prop}'").stdout.strip()
    print('8 identical create commands: one room-cleaning task and checklist.')
    results=race([actor(u,f"select public.claim_task('{task}')")for u in [hk1,hk2]])
    assert sum(r.returncode==0 for r in results)==1, str([r.stderr for r in results])
    assert all(not r.returncode or '22023' in r.stderr for r in results), str([r.stderr for r in results])
    print('Two workers claiming one room: exactly one assignee.')
    item=sql(f"select id from public.task_checklists where task_id='{task}'").stdout.strip()
    for i in range(8):
        if i:
            sql(actor(owner,f"select public.set_task_status('{task}','open')")) if sql(f"select status from public.tasks where id='{task}'").stdout.strip()=='done' else None
        version=sql(f"select version from public.tasks where id='{task}'").stdout.strip()
        sql(actor(owner,f"select public.task_action('{prop}','{task}',{version},'{uuid.uuid4()}','check','{{\"item\":\"{item}\",\"done\":true}}')"))
        version=sql(f"select version from public.tasks where id='{task}'").stdout.strip()
        queries=[actor(owner,f"select public.task_action('{prop}','{task}',{version},'{uuid.uuid4()}','check','{{\"item\":\"{item}\",\"done\":false}}')"),actor(owner,f"select public.task_action('{prop}','{task}',{version},'{uuid.uuid4()}','status','{{\"status\":\"done\"}}')")]
        results=race(queries)
        assert sum(r.returncode==0 for r in results)==1, str([r.stderr for r in results])
        assert all(not r.returncode or '40001' in r.stderr for r in results), str([r.stderr for r in results])
        state=sql(f"select t.status||'|'||c.done||'|'||u.housekeeping_status from public.tasks t join public.task_checklists c on c.task_id=t.id join public.accommodation_units u on u.id=t.unit_id where t.id='{task}'").stdout.strip()
        assert state in ('done|true|clean','open|false|dirty'), state
    print('8 checklist-versus-completion races: no completed task with unchecked work; room status consistent.')
    for i in range(4):
        if sql(f"select status from public.tasks where id='{task}'").stdout.strip()!='done':
            for checklist_item in sql(f"select id from public.task_checklists where task_id='{task}'and not done").stdout.splitlines():
                version=sql(f"select version from public.tasks where id='{task}'").stdout.strip()
                sql(actor(owner,f"select public.task_action('{prop}','{task}',{version},'{uuid.uuid4()}','check','{{\"item\":\"{checklist_item}\",\"done\":true}}')"))
            sql(actor(owner,f"select public.set_task_status('{task}','done')"))
        details=json.dumps({'title':'Next cleaning','kind':'housekeeping','priority':'normal','unit':room,'checklist':[]})
        results=race([actor(owner,f"select public.set_task_status('{task}','open')"),actor(owner,f"select public.task_create_advanced('{prop}','{uuid.uuid4()}','{details}')")])
        assert sum(r.returncode==0 for r in results)==1, str([r.stderr for r in results])
        assert all(not r.returncode or '23505' in r.stderr for r in results), str([r.stderr for r in results])
        active=sql(f"select id from public.tasks where unit_id='{room}'and status in('open','in_progress')").stdout.splitlines()
        assert len(active)==1, active
        task=active[0]
        assert sql(f"select housekeeping_status from public.accommodation_units where id='{room}'").stdout.strip()=='dirty'
    print('4 reopening-versus-new-cleaning races: exactly one active room task, no lock inversion.')
finally:
    sql(f"""begin;
    delete from public.task_comments where property_id='{prop}';
    delete from public.tasks where property_id='{prop}';
    delete from public.tenants where id='{tenant}';
    delete from auth.users where id in('{owner}','{hk1}','{hk2}');commit;""")
    assert sql(f"select count(*)from public.tenants where id='{tenant}'").stdout.strip()=='0'
    print('Isolated task-test fixtures removed.')

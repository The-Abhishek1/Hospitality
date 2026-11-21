"""Local-only service task/cancellation races; UUID fixtures are deleted in finally."""
import concurrent.futures
import json
import subprocess
import threading
import uuid

DB = 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
user, tenant, prop, guest, stay = [str(uuid.uuid4()) for _ in range(5)]

def sql(query, required=True):
    r = subprocess.run(['psql', DB, '-XqAt', '-v', 'ON_ERROR_STOP=1', '-c', query], capture_output=True, text=True, timeout=20)
    if required and r.returncode:
        raise RuntimeError(r.stderr)
    return r

def actor(query):
    return "begin;set local lock_timeout='5s';set local role authenticated;select set_config('request.jwt.claims','"+json.dumps({'sub': user, 'role': 'authenticated'})+"',true);"+query+";commit;"

try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{user}','service-race-{user}@test.invalid');
    insert into public.tenants(id,name,slug)values('{tenant}','Service test','service-race-{tenant}');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{user}','owner');
    insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Service test','hotel');
    insert into public.guests(id,tenant_id,full_name)values('{guest}','{tenant}','Service test guest');
    insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('{stay}','{tenant}','{prop}','{guest}','checked_in',current_date-1,current_date+1,0,'INR');commit;""")
    for i in range(8):
        request = sql(actor(f"select public.create_guest_request('{prop}','{stay}',null,'Race request {i}')")).stdout.splitlines()[-1]
        sql(actor(f"select public.service_desk_action('{prop}','{request}',(select version from public.guest_requests where id='{request}'),'{uuid.uuid4()}','attach_task','{{\"kind\":\"general\"}}')"))
        task = sql(f"select id from public.tasks where guest_request_id='{request}'").stdout.strip()
        barrier = threading.Barrier(2)
        def run(query):
            barrier.wait()
            return sql(actor(query), False)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(run, [f"select public.cancel_guest_request('{request}','Guest changed plans')", f"select public.set_task_status('{task}','done')"]))
        assert any(r.returncode == 0 for r in results), 'Neither operation succeeded'
        assert all(not r.returncode or '22023' in r.stderr or 'invalid' in r.stderr.lower() or 'resolved' in r.stderr.lower() or 'complete' in r.stderr.lower() or 'transition' in r.stderr.lower() for r in results), str([r.stderr for r in results])
        state = sql(f"select g.status||'|'||t.status from public.guest_requests g join public.tasks t on t.guest_request_id=g.id where g.id='{request}'").stdout.strip()
        assert state in ('completed|done', 'cancelled|cancelled'), state
    print('8 concurrent task-completion/cancellation races: consistent request/task status, no deadlocks.')
finally:
    sql(f"""begin;
    delete from public.service_desk_commands where property_id='{prop}';
    delete from public.guest_request_comments where property_id='{prop}';
    delete from public.guest_request_feedback where property_id='{prop}';
    delete from public.guest_request_events where property_id='{prop}';
    delete from public.task_events where property_id='{prop}';
    delete from public.task_comments where property_id='{prop}';
    delete from public.tasks where property_id='{prop}';
    delete from public.guest_requests where property_id='{prop}';
    delete from public.reservations where property_id='{prop}';
    delete from public.guests where tenant_id='{tenant}';
    delete from public.properties where id='{prop}';
    delete from public.tenants where id='{tenant}';
    delete from auth.users where id='{user}';commit;""")
    print('Isolated service-test fixtures removed.')

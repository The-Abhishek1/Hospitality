"""Loopback-only deletion races; creates and removes its own synthetic fixture."""
import concurrent.futures
import subprocess
import uuid

DB = 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
admin, tenant, pid, job = [str(uuid.uuid4()) for _ in range(4)]
def sql(query, required=True):
    result = subprocess.run(['psql', DB, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', query], capture_output=True, text=True, timeout=45)
    if required and result.returncode:
        raise RuntimeError(result.stderr)
    return result

def begin(request):
    return f"select public.platform_hotel_deletion_begin('{pid}','{admin}','{request}',1,'Deletion race','Synthetic local race cleanup')"
def finish():
    return f"select public.platform_hotel_deletion_step('{job}','{admin}')"
try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{admin}','deletion-race-{admin}@test.invalid');
    insert into public.platform_admins(user_id)values('{admin}');
    insert into public.tenants(id,name,slug)values('{tenant}','Deletion race','deletion-race-{tenant}');
    insert into public.properties(id,tenant_id,name,property_type)values('{pid}','{tenant}','Deletion race','hotel');commit;""")
    # Read the returned job ID before the transaction commits: the freeze is installed
    # but its property lock is deliberately still held while the competing writer starts.
    process = subprocess.Popen(['psql', DB, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', f'begin;{begin(job)};select pg_sleep(1);commit;'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert process.stdout.readline().strip() == job
    written = sql(f"insert into public.tasks(tenant_id,property_id,title)values('{tenant}','{pid}','Must not survive deletion')", False)
    process.communicate(timeout=20)
    assert process.returncode == 0
    assert written.returncode != 0, 'A competing write escaped the hotel freeze'
    assert sql(f"select count(*)from public.tasks where property_id='{pid}'").stdout.strip() == '0'
    print('PASS A competing write waits for the freeze, then fails without creating a record.')
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(sql, [begin(str(uuid.uuid4())) for _ in range(6)]))
    assert all(result.stdout.strip() == job for result in results)
    assert sql(f"select count(*)from private.hotel_deletions where property_id='{pid}'").stdout.strip() == '1'
    print('PASS Concurrent begin requests converge on one durable deletion job.')
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(sql, [finish()] * 6))
    assert all('"complete"' in result.stdout for result in results)
    assert sql(f"select count(*)from public.platform_audit_logs where action='platform_hotel_deleted'and details->>'property_id'='{pid}'").stdout.strip() == '1'
    print('PASS Concurrent completion requests produce exactly one deletion receipt.')
finally:
    sql(f"""begin;delete from public.tenants where id='{tenant}';
    delete from public.platform_audit_logs where actor_id='{admin}';
    delete from private.hotel_deletions where property_id='{pid}';
    delete from auth.users where id='{admin}';commit;""")

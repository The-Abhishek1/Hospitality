"""Local-only races for calendar edits and booking price snapshots."""
import concurrent.futures
import json
import os
import subprocess
import threading
import uuid
from urllib.parse import urlparse

DB = os.environ.get('PRICING_TEST_DB_URL', 'postgresql://postgres:postgres@127.0.0.1:54322/postgres')
if urlparse(DB).hostname not in ('127.0.0.1', 'localhost', '::1'):
    raise RuntimeError('Pricing concurrency tests require a local database.')
user, tenant, prop, room_type = [str(uuid.uuid4()) for _ in range(4)]

def sql(query, required=True):
    result = subprocess.run(['psql', DB, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', query], capture_output=True, text=True, timeout=40)
    if required and result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result

def actor(query):
    claims = json.dumps({'sub': user, 'role': 'authenticated'})
    return f"begin;set local role authenticated;select set_config('request.jwt.claims','{claims}',true);{query};commit;"

def value(query):
    return sql(actor(query)).stdout.strip().splitlines()[-1]

def race(queries):
    barrier = threading.Barrier(len(queries))
    def run(query):
        barrier.wait()
        return sql(actor(query), required=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries)) as pool:
        return list(pool.map(run, queries))

def change(request, version, price):
    return f"select public.room_pricing_save('{prop}','{request}',{version},'{room_type}',current_date+30,current_date+36,127,{price},false,'Concurrency QA')"

try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{user}','pricing-race-{user}@test.invalid');
    insert into public.tenants(id,name,slug)values('{tenant}','Pricing race','pricing-race-{tenant}');
    insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Pricing race hotel','hotel');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{user}','owner');
    insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('{room_type}','{tenant}','{prop}','Race room',2,3000);
    insert into public.accommodation_units(tenant_id,property_id,type_id,name)values('{tenant}','{prop}','{room_type}','101');
    commit;""")
    version = int(value(f"select public.room_pricing_workspace('{prop}')->>'version'"))
    request = str(uuid.uuid4())
    results = race([change(request, version, 5500)] * 8)
    assert all(r.returncode == 0 for r in results), 'Identical rate requests did not resolve consistently.'
    assert sql(f"select count(*)from private.room_pricing_commands where property_id='{prop}'").stdout.strip() == '1'
    assert sql(f"select count(*)from public.room_date_prices where property_id='{prop}'").stdout.strip() == '7'
    print('8 retries of one weekly edit: one audited change and seven nightly prices.')
    version = int(value(f"select public.room_pricing_workspace('{prop}')->>'version'"))
    results = race([change(str(uuid.uuid4()), version, 6000 + i) for i in range(8)])
    assert sum(r.returncode == 0 for r in results) == 1, 'Competing edits silently overwrote one another.'
    assert all('deadlock detected' not in r.stderr for r in results), 'Calendar edits deadlocked.'
    print('8 competing edits: one wins; seven receive a stale-calendar rejection.')
    version = int(value(f"select public.room_pricing_workspace('{prop}')->>'version'"))
    total = value(f"select public.frontdesk_quote('{prop}','{room_type}',current_date+30,current_date+37,1,0)->>'total'")
    booking = f"select public.frontdesk_create('{prop}','{uuid.uuid4()}','Pricing race guest','','','{room_type}',current_date+30,current_date+37,1,0,null,null,'','direct',{total})"
    results = race([booking, change(str(uuid.uuid4()), version, 9000)])
    assert results[1].returncode == 0, 'Rate change did not complete.'
    assert all('deadlock detected' not in r.stderr for r in results), 'Booking and rate edit deadlocked.'
    if results[0].returncode == 0:
        row = sql(f"select r.total_amount=(select sum(amount)from public.reservation_nightly_prices where reservation_id=r.id)and r.total_amount={total} from public.reservations r where property_id='{prop}'").stdout.strip()
        assert row == 't', 'Booking mixed pre-change and post-change nightly prices.'
    else:
        assert 'rate changed' in results[0].stderr.lower(), 'Booking failed for an unexpected reason.'
        assert sql(f"select count(*)from public.reservations where property_id='{prop}'").stdout.strip() == '0'
    print('Booking versus price change: an unchanged agreed snapshot or a stale-quote rejection, never mixed prices.')
finally:
    sql(f"begin;delete from public.reservation_nightly_prices where tenant_id='{tenant}';delete from public.tenants where id='{tenant}';delete from auth.users where id='{user}';commit;")
    print('Synthetic pricing race fixtures removed.')

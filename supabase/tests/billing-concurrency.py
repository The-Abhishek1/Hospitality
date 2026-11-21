"""Local database races for financial idempotency and invoice locking.
Uses isolated UUID fixtures; it does not process real payments or refunds.
"""
import concurrent.futures
import json
import os
import subprocess
import threading
import uuid

DB = os.environ.get('BILLING_TEST_DB_URL', 'postgresql://postgres:postgres@127.0.0.1:54322/postgres')
user, tenant, prop, guest, stay, other = [str(uuid.uuid4()) for _ in range(6)]

def sql(query, required=True):
    try:
        result = subprocess.run(['psql', DB, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', query], capture_output=True, text=True, timeout=35)
    except subprocess.TimeoutExpired:
        raise RuntimeError('Local billing race timed out.') from None
    if required and result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result

def actor(query):
    return "begin; set local role authenticated; select set_config('request.jwt.claims','" + json.dumps({'sub': user, 'role': 'authenticated'}) + "',true); " + query + "; commit;"

def race(queries):
    barrier = threading.Barrier(len(queries))
    def run(query):
        barrier.wait()
        return sql(actor(query), required=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries)) as pool:
        return list(pool.map(run, queries))

try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{user}','billing-race-{user}@test.invalid');
    insert into public.tenants(id,name,slug)values('{tenant}','Billing race','race-{tenant}');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{user}','owner');
    insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Billing race hotel','hotel');
    insert into public.guests(id,tenant_id,full_name)values('{guest}','{tenant}','Race guest');
    insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('{stay}','{tenant}','{prop}','{guest}','checked_in',current_date-1,current_date+1,200,'INR'),('{other}','{tenant}','{prop}','{guest}','checked_in',current_date-1,current_date+1,100,'INR');
    commit;""")
    sql(actor(f"select public.post_room_charges('{stay}');select public.post_room_charges('{other}')"))
    request = str(uuid.uuid4())
    payment = f"select public.billing_action('{prop}','{stay}','{request}','payment','{{\"expected_balance\":200,\"amount\":\"200.00\",\"method\":\"cash\"}}')"
    results = race([payment] * 8)
    assert all(r.returncode == 0 for r in results), 'Idempotent payment requests did not all resolve.'
    assert sql(f"select count(*) from public.payments where property_id='{prop}'").stdout.strip() == '1', 'Duplicate payment recorded.'
    print('8 concurrent copies of one payment request: one payment recorded.')
    results = race([f"select public.finalize_invoice((select id from public.folios where reservation_id='{stay}'))"] * 8)
    assert all(r.returncode == 0 for r in results), 'Concurrent invoice requests failed.'
    assert sql(f"select count(*) from public.invoices where property_id='{prop}'").stdout.strip() == '1', 'Duplicate invoice issued.'
    print('8 concurrent invoice requests: one fixed invoice issued.')
    payment_id = sql(f"select id from public.payments where property_id='{prop}'").stdout.strip()
    queries = [f"select public.billing_action('{prop}','{stay}','{uuid.uuid4()}','refund','{{\"expected_balance\":0,\"payment_id\":\"{payment_id}\",\"amount\":\"150.00\",\"reason\":\"Race refund\"}}')" for _ in range(8)]
    results = race(queries)
    assert sum(r.returncode == 0 for r in results) == 1, 'Concurrent refunds exceeded payment capacity.'
    assert sql(f"select count(*) from public.credit_notes where property_id='{prop}'").stdout.strip() == '1', 'Credit-note count does not match successful refund.'
    assert sql(f"select private.folio_balance_raw(id) from public.folios where reservation_id='{stay}'").stdout.strip() == '0.00', 'Closed folio became unsettled after credit/refund.'
    print('8 competing refunds: one eligible refund and matching credit note.')
    sql(actor(f"select public.collect_folio_payment((select id from public.folios where reservation_id='{other}'),100,'cash')"))
    results = race([f"select public.finalize_invoice((select id from public.folios where reservation_id='{other}'))", f"select public.billing_action('{prop}','{other}','{uuid.uuid4()}','charge','{{\"expected_balance\":0,\"amount\":\"10.00\",\"description\":\"Concurrent charge\"}}')"])
    assert sum(r.returncode == 0 for r in results) == 1, 'Invoice/charge race did not serialize.'
    row = sql(f"select status||'|'||private.folio_balance_raw(id)::text from public.folios where reservation_id='{other}'").stdout.strip()
    assert row in ('closed|0.00', 'open|10.00'), 'Invoice closed with an unaccounted charge.'
    print('Invoice versus new charge: serialized without an unbalanced closed folio.')
finally:
    sql(f"""begin;
    delete from public.billing_events where tenant_id='{tenant}';
    delete from public.credit_notes where tenant_id='{tenant}';
    delete from public.night_audit_runs where tenant_id='{tenant}';
    delete from public.credit_note_counters where property_id='{prop}';
    delete from public.refunds where tenant_id='{tenant}';
    delete from public.invoices where tenant_id='{tenant}';
    delete from public.payments where tenant_id='{tenant}';
    delete from public.folio_items where tenant_id='{tenant}';
    delete from public.folios where tenant_id='{tenant}';
    delete from public.tenants where id='{tenant}';
    delete from auth.users where id='{user}';
    commit;""")

    assert sql(f"select count(*) from public.tenants where id='{tenant}'").stdout.strip() == '0', 'Race fixtures were not removed.'
    print('Temporary billing fixtures removed.')

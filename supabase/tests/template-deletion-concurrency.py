"""Isolated regression: template deletion and event activation cannot both win."""
import concurrent.futures
import os
import subprocess
import time
import uuid

URL = os.environ.get('TEMPLATE_TEST_DB', 'postgresql://postgres:postgres@127.0.0.1:54322/hospitality_qa_regression')
if not URL.endswith('/hospitality_qa_regression'):
    raise SystemExit('Run this regression only against hospitality_qa_regression.')
uid, tenant, pid, cid, tid = [str(uuid.uuid4()) for _ in range(5)]
def sql(query):
    return subprocess.run(['psql', URL, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], capture_output=True, text=True)
def run(query):
    result = sql(query)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout
claims = f"set local role authenticated; select set_config('request.jwt.claims','{{\"sub\":\"{uid}\",\"role\":\"authenticated\"}}',true);"
begin = f"select public.begin_whatsapp_template_deletion('{pid}','{tid}','901','deletion_race_qa','en_US');"
activate = f"select public.save_whatsapp_automation_rule('{pid}','checked_in',0,true,'{tid}','[]',0);"
setup = f"""
insert into auth.users(id,email)values('{uid}','{uid}@race.test.invalid');
insert into public.tenants(id,name,slug)values('{tenant}','Deletion race QA','race-{tenant}');
insert into public.properties(id,tenant_id,name,property_type)values('{pid}','{tenant}','Deletion race QA','hotel');
insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{uid}','owner');
insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref)values('{cid}','{tenant}','{pid}','{uuid.uuid4().int % 10**15}','{uuid.uuid4().int % 10**15}','+919999999999','race-qa');
insert into public.message_templates(id,tenant_id,property_id,name,language,category,status,body,provider_template_id,provider_waba_id,provider_status,provider_checked_at,automation_supported,service_supported,parameter_names)
select '{tid}','{tenant}','{pid}','deletion_race_qa','en_US','utility','approved','Synthetic race template','901',waba_id,'APPROVED',now(),true,true,'[]'from public.whatsapp_connections where id='{cid}';
"""
def race(first, second, lock_query):
    with concurrent.futures.ThreadPoolExecutor() as pool:
        future = pool.submit(sql, 'begin;'+claims+first+'select pg_sleep(1);commit;')
        # Wait for the first operation's transaction-held lock, not a guessed startup delay.
        for _ in range(100):
            if run(lock_query).strip() == 't':
                break
            time.sleep(.02)
        else:
            raise RuntimeError('First operation did not acquire its lock.')
        later = pool.submit(sql, 'begin;'+claims+second+'commit;')
        a, b = future.result(timeout=10), later.result(timeout=10)
        assert a.returncode == 0, a.stderr
        assert b.returncode != 0 and 'ERROR:' in b.stderr and 'deadlock' not in b.stderr.lower(), b.stderr
try:
    run(setup)
    # Detect a granted transaction advisory lock; fixture is the only deletion operation here.
    lock_query = f"select exists(select 1 from pg_locks where locktype='advisory'and granted and database=(select oid from pg_database where datname=current_database())and classid::bigint=((hashtextextended('wa-template-delete:{tid}',0)>>32)&4294967295)and objid::bigint=(hashtextextended('wa-template-delete:{tid}',0)&4294967295));"
    race(begin, activate, lock_query)
    assert run(f"select count(*)from public.whatsapp_automation_rules where property_id='{pid}'and enabled;").strip() == '0'
    print('PASS deletion wins: concurrent activation waits and is rejected without a deadlock')
    run(f"delete from private.whatsapp_template_deletions where property_id='{pid}';")
    # The activation updates the property row and acquires the template-use advisory lock.
    race(activate, begin, lock_query)
    assert run(f"select count(*)from private.whatsapp_template_deletions where property_id='{pid}';").strip() == '0'
    print('PASS activation wins: concurrent deletion waits and reports active usage')
finally:
    run(f"delete from private.whatsapp_template_deletions where property_id='{pid}'; delete from public.whatsapp_automation_audit where property_id='{pid}'; delete from public.whatsapp_automation_rules where property_id='{pid}'; delete from public.message_templates where property_id='{pid}'; delete from public.whatsapp_connections where property_id='{pid}'; delete from public.properties where id='{pid}'; delete from public.tenants where id='{tenant}'; delete from auth.users where id='{uid}';")

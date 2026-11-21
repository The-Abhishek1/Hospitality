"""Local reviewed-settings and currency/first-financial-record races, with isolated fixtures."""
import concurrent.futures
import json
import subprocess
import threading
import uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,guest=[str(uuid.uuid4())for _ in range(3)]

def sql(query,required=True):
    r=subprocess.run(['psql',DB,'-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',query],capture_output=True,text=True,timeout=25)
    if required and r.returncode:raise RuntimeError(r.stderr)
    return r

def actor(query):
    return "begin;set local lock_timeout='5s';set local role authenticated;select set_config('request.jwt.claims','"+json.dumps({'sub':owner,'role':'authenticated'})+"',true);"+query+";commit;"

def race(queries):
    barrier=threading.Barrier(len(queries))
    def run(query):
        barrier.wait();return sql(actor(query),False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries))as pool:return list(pool.map(run,queries))

def fixture():
    prop,room_type,room,category,menu=[str(uuid.uuid4())for _ in range(5)]
    sql(f"""begin;
    insert into public.properties(id,tenant_id,name,property_type,timezone,currency)values('{prop}','{tenant}','Settings test','hotel','UTC','INR');
    insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('{room_type}','{tenant}','{prop}','Standard',2,100);
    insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('{room}','{tenant}','{prop}','{room_type}','101');
    insert into public.menu_categories(id,tenant_id,property_id,name)values('{category}','{tenant}','{prop}','Drinks');
    insert into public.menu_items(id,tenant_id,property_id,category_id,name,price,tax_rate_percent)values('{menu}','{tenant}','{prop}','{category}','Tea',10,0);commit;""")
    return prop,room_type,room,menu

def save(prop,section,details,request=None,pv=1,sv=1):
    return f"select public.property_settings_save('{prop}',{pv},{sv},'{request or uuid.uuid4()}','{section}','{json.dumps(details)}')"

try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{owner}','settings-race-{owner}@test.invalid');
    insert into public.tenants(id,name,slug)values('{tenant}','Settings test','settings-race-{tenant}');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');
    insert into public.guests(id,tenant_id,full_name)values('{guest}','{tenant}','Settings test guest');commit;""")
    prop,room_type,room,menu=fixture()
    command=save(prop,'guest',{'check_in_time':'15:00','check_out_time':'10:00','arrival_instructions':'Reception entrance','stay_information':'Quiet hours after 22:00','reason':'Test guest information'},str(uuid.uuid4()))
    results=race([command]*8);assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
    assert sql(f"select count(*)from public.property_settings_events where property_id='{prop}'").stdout.strip()=='1'
    print('8 identical settings submissions: one saved change and audit event.')
    sv=sql(f"select version from public.property_settings where property_id='{prop}'").stdout.strip()
    details=[{'name':'Updated identity','property_type':'hotel','country_code':'IN','reason':'Test identity'}, {'check_in_time':'16:00','check_out_time':'11:00','reason':'Test competing guest edit'}]
    results=race([save(prop,'identity',details[0],sv=sv),save(prop,'guest',details[1],sv=sv)])
    assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
    assert all(not r.returncode or '40001'in r.stderr for r in results),str([r.stderr for r in results])
    print('Two edits based on one configuration version: one succeeds, the stale edit is rejected.')
    for mode in ['legacy_booking','reviewed_booking','legacy_order','reviewed_order']:
        for _ in range(3):
            prop,room_type,room,menu=fixture()
            change=save(prop,'localization',{'timezone':'UTC','currency':'USD','confirm_currency':True,'reason':'Review first operating currency'})
            if mode=='legacy_booking':
                create=f"select public.create_reservation('{prop}','{guest}','{room_type}',current_date+1,current_date+2)"
            elif mode=='reviewed_booking':
                create=f"select public.frontdesk_create_reviewed('{prop}','INR','{uuid.uuid4()}','Test guest',null,null,'{room_type}',current_date+1,current_date+2,1,0,null,'{room}',null,'direct',100)"
            elif mode=='legacy_order':
                create=f"select public.place_order('{prop}','restaurant','[{{\"menu_item_id\":\"{menu}\",\"quantity\":1}}]');select currency from public.properties where id='{prop}'"
            else:
                details={'kind':'restaurant','quote':'10.00','expected_currency':'INR','items':[{'menu_item_id':menu,'version':1,'quantity':1}]}
                create=f"select public.orders_create('{prop}','{uuid.uuid4()}','{json.dumps(details)}')"
            results=race([change,create])
            assert any(r.returncode==0 for r in results),(mode,[r.stderr for r in results])
            assert all(not r.returncode or any(code in r.stderr for code in ['22023','40001'])for r in results),(mode,[r.stderr for r in results])
            if mode.startswith('reviewed'):
                assert sum(r.returncode==0 for r in results)==1,(mode,[r.stderr for r in results])
            if 'booking'in mode:
                assert sql(f"select not exists(select 1 from public.reservations r join public.properties p on p.id=r.property_id where p.id='{prop}'and r.currency<>p.currency)").stdout.strip()=='t'
            elif results[1].returncode==0:
                expected=results[1].stdout.splitlines()[-1]if mode=='legacy_order'else 'INR'
                assert sql(f"select currency from public.properties where id='{prop}'").stdout.strip()==expected
        print(f'3 {mode}-versus-currency-change races: consistent currency or stale-review rejection.')
finally:
    sql(f"""begin;
    delete from public.orders where tenant_id='{tenant}';
    delete from public.unit_holds where tenant_id='{tenant}';
    delete from public.reservations where tenant_id='{tenant}';
    delete from public.tenants where id='{tenant}';
    delete from auth.users where id='{owner}';commit;""")
    assert sql(f"select count(*)from public.tenants where id='{tenant}'").stdout.strip()=='0'
    print('Isolated settings-test fixtures removed.')

"""Local inventory/booking races with isolated UUID fixtures and explicit cleanup."""
import concurrent.futures
import json
import subprocess
import threading
import uuid

DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,prop,type_a,type_b,room,guest=[str(uuid.uuid4())for _ in range(7)]

def sql(query,required=True):
    r=subprocess.run(['psql',DB,'-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',query],capture_output=True,text=True,timeout=25)
    if required and r.returncode:raise RuntimeError(r.stderr)
    return r

def actor(query):
    return "begin;set local lock_timeout='5s';set local role authenticated;select set_config('request.jwt.claims','"+json.dumps({'sub':owner,'role':'authenticated'})+"',true);"+query+";commit;"

def race(queries):
    barrier=threading.Barrier(len(queries))
    def run(query):
        barrier.wait()
        return sql(actor(query),False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries))as pool:return list(pool.map(run,queries))

def save(section,item,version,details,request=None):
    item_sql="null"if item is None else "'"+item+"'"
    return f"select public.inventory_save('{prop}','{request or uuid.uuid4()}','{section}',{item_sql},{'null'if version is None else version},'{json.dumps(details)}')"

def room_settings(active=True,room_type=None):
    version=sql(f"select version from public.accommodation_units where id='{room}'").stdout.strip()
    return save('rooms',room,version,{'name':'Race room','type_id':room_type or type_a,'active':active})

def capacity_settings(capacity):
    version=sql(f"select version from public.accommodation_types where id='{type_a}'").stdout.strip()
    return save('types',type_a,version,{'name':'Type A','kind':'room','capacity':capacity,'base_rate':'100.00'})

def clear_bookings():
    for reservation in sql(f"select id from public.reservations where property_id='{prop}'and status='confirmed'").stdout.splitlines():
        sql(actor(f"select public.cancel_reservation('{reservation}')"))

def booking(adults=2):
    return f"select public.create_reservation('{prop}','{guest}','{type_a}',current_date+7,current_date+9,{adults},0)"

try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{owner}','inventory-race-{owner}@test.invalid');
    insert into public.tenants(id,name,slug)values('{tenant}','Inventory test','inv-race-{tenant}');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');
    insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Inventory test','hotel');
    insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('{type_a}','{tenant}','{prop}','Type A',4,100),('{type_b}','{tenant}','{prop}','Type B',4,200);
    insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('{room}','{tenant}','{prop}','{type_a}','Race room');
    insert into public.guests(id,tenant_id,full_name)values('{guest}','{tenant}','Race guest');commit;""")
    for mode in ['deactivate','retype','capacity']:
        for _ in range(4):
            clear_bookings();sql(actor(room_settings()));sql(actor(capacity_settings(4)))
            change=room_settings(False)if mode=='deactivate'else room_settings(room_type=type_b)if mode=='retype'else capacity_settings(2)
            results=race([booking(4),change])
            assert sum(r.returncode==0 for r in results)==1,(mode,[r.stderr for r in results])
            assert all(not r.returncode or any(code in r.stderr for code in ['22023','P0002'])for r in results),(mode,[r.stderr for r in results])
            valid=sql(f"select not exists(select 1 from public.unit_holds h join public.reservations r on r.id=h.reservation_id join public.accommodation_units u on u.id=h.unit_id join public.accommodation_types t on t.id=u.type_id where h.unit_id='{room}'and h.active and(not u.active or u.type_id<>'{type_a}'or r.adults+r.children>t.max_occupancy))").stdout.strip()
            assert valid=='t',mode
        print(f'4 booking-versus-{mode} races: one valid outcome, no booking stranded on incompatible inventory.')
    clear_bookings();sql(actor(room_settings()))
    request=str(uuid.uuid4());from_day=sql('select(current_date+30)::text').stdout.strip();to_day=sql('select(current_date+32)::text').stdout.strip()
    command=save('blocks',None,None,{'unit_id':room,'from':from_day,'to':to_day,'reason':'Test repairs'},request)
    results=race([command]*8)
    assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
    assert sql(f"select count(*)from public.unit_holds where property_id='{prop}'and kind='block'").stdout.strip()=='1'
    print('8 identical block commands: exactly one recorded block.')
    for name in ['Race room 2','Race room 3']:
        sql(f"insert into public.accommodation_units(tenant_id,property_id,type_id,name)values('{tenant}','{prop}','{type_a}','{name}')")
    results=race([booking(2)]*12)
    assert sum(r.returncode==0 for r in results)==3,str([r.stderr for r in results])
    assert all(not r.returncode or 'P0002' in r.stderr for r in results),str([r.stderr for r in results])
    assert sql(f"select count(distinct unit_id)from public.unit_holds where property_id='{prop}'and kind='reservation'and active").stdout.strip()=='3'
    print('12 competing bookings for 3 rooms: exactly 3 bookings, no overbooking.')
finally:
    sql(f"""begin;
    delete from public.tasks where property_id='{prop}';
    delete from public.unit_holds where property_id='{prop}';
    delete from public.reservations where property_id='{prop}';
    delete from public.tenants where id='{tenant}';
    delete from auth.users where id='{owner}';commit;""")
    assert sql(f"select count(*)from public.tenants where id='{tenant}'").stdout.strip()=='0'
    print('Isolated inventory-test fixtures removed.')

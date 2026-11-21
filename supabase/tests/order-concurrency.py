"""Local order/menu/payment races using UUID fixtures, removed in finally."""
import concurrent.futures
import json
import subprocess
import threading
import uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,prop,category,menu,guest,stay,invoice_stay=[str(uuid.uuid4())for _ in range(8)]

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

def create_command(request=None,reservation=None):
    version=int(sql(f"select version from public.menu_items where id='{menu}'").stdout.strip())
    details={'kind':'room_service'if reservation else 'restaurant','reservation_id':reservation,'quote':'110.00','items':[{'menu_item_id':menu,'version':version,'quantity':1}]}
    return f"select public.orders_create('{prop}','{request or uuid.uuid4()}','{json.dumps(details)}')"

def operation(order,version,request,action,details):
    return f"select public.order_action('{prop}','{order}',{version},'{request}','{action}','{json.dumps(details)}')"

def ready(order):
    sql(actor(f"select public.set_order_status('{order}','preparing');select public.set_order_status('{order}','ready')"))

try:
    sql(f"""begin;
    insert into auth.users(id,email)values('{owner}','order-race-{owner}@test.invalid');
    insert into public.tenants(id,name,slug)values('{tenant}','Order test','order-race-{tenant}');
    insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');
    insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Order test','hotel');
    insert into public.menu_categories(id,tenant_id,property_id,name)values('{category}','{tenant}','{prop}','Mains');
    insert into public.menu_items(id,tenant_id,property_id,category_id,name,price,tax_rate_percent)values('{menu}','{tenant}','{prop}','{category}','Test meal',100,10);
    insert into public.guests(id,tenant_id,full_name)values('{guest}','{tenant}','Test guest');
    insert into public.reservations(id,tenant_id,property_id,guest_id,status,check_in,check_out,total_amount,currency)values('{stay}','{tenant}','{prop}','{guest}','checked_in',current_date,current_date+1,100,'INR'),('{invoice_stay}','{tenant}','{prop}','{guest}','checked_in',current_date,current_date+1,100,'INR');commit;""")
    command=create_command(str(uuid.uuid4()));results=race([command]*8)
    assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
    order=sql(f"select id from public.orders where property_id='{prop}'").stdout.strip()
    assert sql(f"select count(*)from public.orders where property_id='{prop}'").stdout.strip()=='1'
    print('8 identical order submissions: one order and one item snapshot.')
    ready(order);sql(actor(f"select public.set_order_status('{order}','served')"))
    version=sql(f"select version from public.orders where id='{order}'").stdout.strip()
    payment=operation(order,version,str(uuid.uuid4()),'payment',{'method':'cash','expected_total':'110.00','reference':'Test receipt'})
    results=race([payment]*8);assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
    assert sql(f"select count(*)from public.payments where order_id='{order}'").stdout.strip()=='1'
    print('8 identical payment submissions: one received-payment record.')
    payment_id=sql(f"select id from public.payments where order_id='{order}'").stdout.strip();version=sql(f"select version from public.orders where id='{order}'").stdout.strip()
    results=race([operation(order,version,str(uuid.uuid4()),'refund',{'payment_id':payment_id,'amount':'80.00','expected_refundable':'110.00','reason':'Test refund'})for _ in range(8)])
    assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
    assert all(not r.returncode or '40001'in r.stderr for r in results),str([r.stderr for r in results])
    assert sql(f"select sum(amount)from public.refunds where payment_id='{payment_id}'").stdout.strip()=='80.00'
    print('8 competing refunds: one refund within the original payment amount.')
    for _ in range(4):
        version=sql(f"select version from public.menu_items where id='{menu}'").stdout.strip()
        change=f"select public.order_menu_save('{prop}','{uuid.uuid4()}','{menu}',{version},'{{\"name\":\"Test meal\",\"category\":\"Mains\",\"price\":\"200.00\",\"tax\":\"10\",\"active\":true}}')"
        results=race([create_command(),change]);assert results[1].returncode==0,results[1].stderr
        assert results[0].returncode==0 or '40001'in results[0].stderr,results[0].stderr
        assert sql(f"select not exists(select 1 from public.orders o join public.order_items i on i.order_id=o.id where o.property_id='{prop}'and(o.total<>110 or i.unit_price<>100))").stdout.strip()=='t'
        sql(f"update public.menu_items set price=100 where id='{menu}'")
    print('4 menu-edit versus order-create races: stable snapshots or a stale-price rejection.')
    room_order=sql(actor(create_command(reservation=stay))).stdout.splitlines()[-1];ready(room_order)
    version=sql(f"select version from public.orders where id='{room_order}'").stdout.strip();serve=operation(room_order,version,str(uuid.uuid4()),'status',{'status':'served'})
    results=race([serve]*8);assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
    assert sql(f"select count(*)from public.folio_items where order_id='{room_order}'").stdout.strip()=='1'
    print('8 identical serving submissions: one room-folio charge.')
    invoice_order=sql(actor(create_command(reservation=invoice_stay))).stdout.splitlines()[-1];ready(invoice_order)
    sql(actor(f"select public.post_room_charges('{invoice_stay}');select public.collect_folio_payment((select id from public.folios where reservation_id='{invoice_stay}'),210,'cash')"))
    results=race([f"select public.set_order_status('{invoice_order}','served')",f"select public.finalize_invoice((select id from public.folios where reservation_id='{invoice_stay}'))"])
    assert results[0].returncode==0,results[0].stderr
    assert results[1].returncode==0 or '22023'in results[1].stderr,results[1].stderr
    assert sql(f"select private.folio_balance_raw(id)from public.folios where reservation_id='{invoice_stay}'").stdout.strip()=='0.00'
    assert sql(f"select count(*)from public.folio_items where order_id='{invoice_order}'").stdout.strip()=='1'
    print('Serving versus invoice finalization: consistent charge and zero balance, no lock inversion.')
finally:
    sql(f"""begin;
    delete from public.billing_events where tenant_id='{tenant}';
    delete from public.credit_notes where tenant_id='{tenant}';
    delete from public.refunds where tenant_id='{tenant}';
    delete from public.invoices where tenant_id='{tenant}';
    delete from public.payments where tenant_id='{tenant}';
    delete from public.folio_items where tenant_id='{tenant}';
    delete from public.folios where tenant_id='{tenant}';
    delete from public.orders where property_id='{prop}';
    delete from public.tenants where id='{tenant}';
    delete from auth.users where id='{owner}';commit;""")
    assert sql(f"select count(*)from public.tenants where id='{tenant}'").stdout.strip()=='0'
    print('Isolated order-test fixtures removed.')

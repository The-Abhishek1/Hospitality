"""Local, isolated checks for competing group allocations and replayed submissions."""
import concurrent.futures,json,subprocess,threading,uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,hotel,room_type=[str(uuid.uuid4())for _ in range(4)]
def sql(query,check=True):
 r=subprocess.run(['psql',DB,'-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',query],capture_output=True,text=True,timeout=40)
 if check and r.returncode:raise RuntimeError(r.stderr)
 return r
def actor(query):
 claims=json.dumps({'sub':owner,'role':'authenticated'})
 return f"begin;set local lock_timeout='10s';set local role authenticated;do $$begin perform set_config('request.jwt.claims','{claims}',true);end$$;{query};commit;"
def race(commands):
 barrier=threading.Barrier(len(commands))
 def run(cmd):barrier.wait();return sql(cmd,False)
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(commands))as pool:return list(pool.map(run,commands))
def reviewed(offset):
 base=json.dumps([{'type_id':room_type,'adults':1,'children':0,'name':'Race group lead','same_guest':False},{'type_id':room_type,'adults':1,'children':0,'same_guest':True}])
 preview=json.loads(sql(actor(f"select public.frontdesk_group_quote('{hotel}',current_date+{offset},current_date+{offset+1},'{base}')")).stdout.strip())
 return json.dumps([{**row,**preview['rows'][n]}for n,row in enumerate(json.loads(base))])
def command(request,items,offset,name):return actor(f"select public.frontdesk_group_create('{hotel}','INR','{request}','{name}','reservation',current_date+{offset},current_date+{offset+1},'{items}')")
try:
 sql(f"""begin;insert into auth.users(id,email,email_confirmed_at)values('{owner}','group-race-{owner}@example.test',now());insert into public.tenants(id,name,slug)values('{tenant}','Group race QA','group-race-{tenant}');insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');insert into public.properties(id,tenant_id,name,property_type,timezone)values('{hotel}','{tenant}','Group race hotel','hotel','UTC');insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('{room_type}','{tenant}','{hotel}','Standard',2,100);insert into public.accommodation_units(tenant_id,property_id,type_id,name)select '{tenant}','{hotel}','{room_type}','R'||n from generate_series(1,4)n;commit;""")
 items=reviewed(5);out=race([command(str(uuid.uuid4()),items,5,'Competing group')for _ in range(2)])
 assert sum(r.returncode==0 for r in out)==1,[r.stderr for r in out]
 assert all(not r.returncode or '22023'in r.stderr for r in out),[r.stderr for r in out]
 assert sql(f"select count(*)from public.reservations where property_id='{hotel}'").stdout.strip()=='2'
 assert sql(f"select count(*)from public.reservation_groups where property_id='{hotel}'").stdout.strip()=='1'
 print('PASS Competing groups cannot allocate the same rooms or leave partial bookings')
 items=reviewed(15);cmd=command(str(uuid.uuid4()),items,15,'Replayed group');out=race([cmd]*8)
 assert all(r.returncode==0 for r in out),[r.stderr for r in out]
 assert len({r.stdout.strip()for r in out})==1
 assert sql(f"select count(*)from public.reservations where property_id='{hotel}'").stdout.strip()=='4'
 assert sql(f"select count(*)from public.reservation_groups where property_id='{hotel}'").stdout.strip()=='2'
 print('PASS Eight simultaneous submissions produce only one group and two room reservations')
finally:
 sql(f"begin;delete from public.tenants where id='{tenant}';delete from auth.users where id='{owner}';commit;")
 print('Isolated group race fixtures removed')

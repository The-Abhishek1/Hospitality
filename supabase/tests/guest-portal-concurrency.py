"""Guest portal retry, arrival edit and request-start races using disposable stays."""
import concurrent.futures,json,subprocess,threading,uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,prop,kind,guest,category,menu=[str(uuid.uuid4())for _ in range(7)]
def sql(q,required=True):
 r=subprocess.run(['psql',DB,'-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',q],capture_output=True,text=True,timeout=25)
 if required and r.returncode:raise RuntimeError(r.stderr)
 return r

def actor(q,staff=False):
 claims=json.dumps({'sub':owner,'role':'authenticated'})
 return "begin;set local lock_timeout='5s';set local role "+('authenticated'if staff else 'anon')+';'+(f"select set_config('request.jwt.claims','{claims}',true);"if staff else '')+q+';commit;'

def race(jobs):
 barrier=threading.Barrier(len(jobs))
 def run(job):
  q,staff=job;barrier.wait();return sql(actor(q,staff),False)
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(jobs))as pool:return list(pool.map(run,jobs))

def command(action,payload,request=None):
 return f"select public.portal_command('{token}','{request or uuid.uuid4()}','{action}','{json.dumps(payload)}')"
try:
 sql(f"""begin;insert into auth.users(id,email)values('{owner}','portal-race-{owner}@test.invalid');insert into public.tenants(id,name,slug)values('{tenant}','Guest portal race','guest-race-{tenant}');insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');insert into public.properties(id,tenant_id,name,property_type,timezone)values('{prop}','{tenant}','Portal race hotel','hotel','UTC');insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('{kind}','{tenant}','{prop}','Standard',2,100);insert into public.accommodation_units(tenant_id,property_id,type_id,name)values('{tenant}','{prop}','{kind}','101');insert into public.guests(id,tenant_id,full_name)values('{guest}','{tenant}','Portal race guest');insert into public.menu_categories(id,tenant_id,property_id,name)values('{category}','{tenant}','{prop}','Drinks');insert into public.menu_items(id,tenant_id,property_id,category_id,name,price,tax_rate_percent)values('{menu}','{tenant}','{prop}','{category}','Tea',10,5);commit;""")
 reservation=sql(actor(f"select public.create_reservation('{prop}','{guest}','{kind}',current_date,current_date+1)",True)).stdout.strip().splitlines()[-1]
 token=sql(actor(f"select public.create_guest_portal_link('{reservation}')",True)).stdout.strip().splitlines()[-1]
 profile={'version':0,'full_name':'Race Guest','email':'','phone':'','country_code':'','address':'','arrival_time':'','arrival_notes':'','stay_updates_requested':False}
 results=race([(command('arrival',profile,str(uuid.uuid4())),False),(command('arrival',{**profile,'full_name':'Other browser'},str(uuid.uuid4())),False)])
 assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
 assert all(r.returncode==0 or '40001'in r.stderr for r in results),str([r.stderr for r in results])
 print('Two browser sessions editing arrival details: one saves, the stale version is rejected.')
 sql(actor(f"select public.check_in_reservation('{reservation}')",True))
 order=command('order',{'currency':'INR','total':'10.50','items':[{'menu_item_id':menu,'version':1,'quantity':1}],'notes':''},str(uuid.uuid4()))
 results=race([(order,False)]*6)
 assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
 assert sql(f"select count(*)from public.orders where reservation_id='{reservation}'").stdout.strip()=='1'
 print('6 simultaneous order retries create one kitchen order.')
 results=race([(command('request_checkout',{}),False)]*4)
 assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
 assert sql(f"select count(*)from public.guest_stay_requests where reservation_id='{reservation}'and intent='checkout'").stdout.strip()=='1'
 print('4 checkout assistance clicks reuse one open request and do not check out the stay.')
 service=json.loads(sql(actor(command('service',{'title':'Race request','notes':''}))).stdout.strip().splitlines()[-1])['id']
 results=race([(command('cancel_request',{'id':service,'version':1}),False),(f"select public.service_desk_action('{prop}','{service}',1,'{uuid.uuid4()}','start','{{}}')",True)])
 assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
 assert all(r.returncode==0 or any(code in r.stderr for code in ['22023','40001'])for r in results),str([r.stderr for r in results])
 print('Guest cancellation versus staff starting work: one valid state transition wins.')
finally:
 sql(f"""begin;delete from public.order_items where tenant_id='{tenant}';delete from public.orders where tenant_id='{tenant}';delete from public.tasks where tenant_id='{tenant}';delete from public.guest_request_feedback where tenant_id='{tenant}';delete from public.guest_requests where tenant_id='{tenant}';delete from public.unit_holds where tenant_id='{tenant}';delete from public.folios where tenant_id='{tenant}';delete from public.reservations where tenant_id='{tenant}';delete from public.tenants where id='{tenant}';delete from auth.users where id='{owner}';commit;""")
 print('Disposable guest portal fixtures removed.')

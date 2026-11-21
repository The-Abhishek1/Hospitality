"""Local campaign scheduling/dispatch races. Only queues test messages; never calls WhatsApp."""
import concurrent.futures,json,subprocess,threading,uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,prop,guest,template=[str(uuid.uuid4())for _ in range(5)]
def sql(q,required=True):
 r=subprocess.run(['psql',DB,'-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',q],capture_output=True,text=True,timeout=25)
 if required and r.returncode:raise RuntimeError(r.stderr)
 return r

def actor(q):
 return "begin;set local lock_timeout='5s';set local role authenticated;select set_config('request.jwt.claims','"+json.dumps({'sub':owner,'role':'authenticated'})+"',true);"+q+";commit;"
def race(queries):
 barrier=threading.Barrier(len(queries))
 def run(q):barrier.wait();return sql(q,False)
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries))as pool:return list(pool.map(run,queries))
try:
 sql(f"begin;insert into auth.users(id,email)values('{owner}','campaign-race-{owner}@test.invalid');insert into public.tenants(id,name,slug)values('{tenant}','Campaign race','campaign-race-{tenant}');insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Campaign race hotel','hotel');insert into public.guests(id,tenant_id,full_name,phone)values('{guest}','{tenant}','Campaign test guest','+919111111111');insert into public.reservations(tenant_id,property_id,guest_id,status,check_in,check_out,adults,total_amount,currency)values('{tenant}','{prop}','{guest}','checked_out',current_date-30,current_date-28,1,200,'INR');insert into public.message_templates(id,tenant_id,property_id,name,category,status,body,campaign_supported)values('{template}','{tenant}','{prop}','campaign_race','marketing','approved','Test offer.',true);commit;")
 sql(actor(f"select public.connect_whatsapp('{prop}','race-{prop}','race-waba','+910000000000','test');select public.record_marketing_permission('{prop}','{guest}','granted','Signed campaign testing permission')"))
 data={'name':'Concurrency offer','body':'Test offer.','filters':{},'selection_mode':'all','selected_guests':[],'template_id':template}
 request=str(uuid.uuid4())
 save=f"select public.save_whatsapp_campaign('{prop}','{request}',null,0,'{json.dumps(data)}')"
 results=race([actor(save)]*6)
 assert all(r.returncode==0 for r in results),[r.stderr for r in results]
 assert sql(f"select count(*)from public.whatsapp_campaigns where property_id='{prop}'").stdout.strip()=='1'
 campaign=sql(f"select id from public.whatsapp_campaigns where property_id='{prop}'").stdout.strip()
 launch=actor(f"select public.launch_whatsapp_campaign('{prop}','{campaign}',1,null)")
 results=race([launch,launch])
 assert sum(r.returncode==0 for r in results)==1,[r.stderr for r in results]
 assert all(r.returncode==0 or '40001'in r.stderr for r in results),[r.stderr for r in results]
 print('Concurrent draft retries and scheduling: one campaign, one frozen recipient.')
 results=race(['select public.dispatch_whatsapp_campaigns(50)']*4)
 assert all(r.returncode==0 for r in results),[r.stderr for r in results]
 assert sql(f"select count(*)from public.messages where campaign_id='{campaign}'").stdout.strip()=='1'
 print('4 simultaneous dispatchers: exactly one queued message, no provider requests.')
 campaign2=sql(actor(f"select public.save_whatsapp_campaign('{prop}','{uuid.uuid4()}',null,0,'{json.dumps(data)}')")).stdout.strip().splitlines()[-1]
 sql(actor(f"select public.launch_whatsapp_campaign('{prop}','{campaign2}',1,null)"))
 results=race(['select public.dispatch_whatsapp_campaigns(50)',actor(f"select public.cancel_whatsapp_campaign('{prop}','{campaign2}',2)")])
 assert all(r.returncode==0 for r in results),[r.stderr for r in results]
 assert sql(f"select status from public.whatsapp_campaigns where id='{campaign2}'").stdout.strip()=='cancelled'
 assert sql(f"select count(*)from public.messages where campaign_id='{campaign2}'and status in('queued','sending')").stdout.strip()=='0'
 print('Cancellation versus expansion: no dispatchable message remains.')
finally:
 sql(f"begin;delete from public.tenants where id='{tenant}';delete from auth.users where id='{owner}';commit;")
 print('Disposable campaign fixtures removed.')

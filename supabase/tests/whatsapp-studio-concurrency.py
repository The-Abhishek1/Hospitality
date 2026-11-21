"""Offline template authoring races. No WhatsApp connection, messages or guest records."""
import concurrent.futures,json,subprocess,threading,uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,prop=[str(uuid.uuid4())for _ in range(3)]
def sql(q,required=True):
 r=subprocess.run(['psql',DB,'-XqAt','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-c',q],capture_output=True,text=True,timeout=25)
 if required and r.returncode:raise RuntimeError(r.stderr)
 return r

def command(section,data,version=0,record=None,request=None):
 return f"select public.whatsapp_studio_save('{prop}','{request or uuid.uuid4()}','{section}',{repr(record)if record else 'null'},{version},'{json.dumps(data)}')"

def actor(q):
 claims=json.dumps({'sub':owner,'role':'authenticated'})
 return f"begin;set local lock_timeout='5s';set local role authenticated;select set_config('request.jwt.claims','{claims}',true);{q};commit;"

def race(queries):
 barrier=threading.Barrier(len(queries))
 def run(q):
  barrier.wait();return sql(actor(q),False)
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries))as pool:return list(pool.map(run,queries))
settings={'portal_origin':'https://stay.example.test','menu_intro':'Welcome to the hotel','menu_items':[{'action':'reception','label':'Reception','enabled':True}]}
content={'name':'concurrency_welcome','language':'en_US','purpose':'welcome','category':'utility','state':'ready','header_kind':'none','header_text':'','image_url':'','body':'Welcome {{guest_name}} to {{hotel_name}}. Open your guest portal.','footer':'Reply STOP to opt out.','buttons':[{'type':'portal','text':'Open guest portal','action':'stay'}]}
try:
 sql(f"begin;insert into auth.users(id,email)values('{owner}','wa-studio-{owner}@test.invalid');insert into public.tenants(id,name,slug)values('{tenant}','Template studio race','wa-race-{tenant}');insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Template race hotel','hotel');commit;")
 sql(actor(command('settings',settings)))
 create=command('template',content,request=str(uuid.uuid4()))
 results=race([create]*6)
 assert all(r.returncode==0 for r in results),str([r.stderr for r in results])
 assert sql(f"select count(*)from public.whatsapp_template_drafts where property_id='{prop}'").stdout.strip()=='1'
 assert sql(f"select count(*)from public.whatsapp_studio_events where property_id='{prop}'and section='template'").stdout.strip()=='1'
 print('6 simultaneous template retries: one draft and one audit event.')
 record=sql(f"select id from public.whatsapp_template_drafts where property_id='{prop}'").stdout.strip()
 results=race([command('template',{**content,'body':'First edited welcome message for {{guest_name}}.'},1,record),command('template',{**content,'body':'Competing welcome message for {{guest_name}}.'},1,record)])
 assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
 assert all(r.returncode==0 or '40001'in r.stderr for r in results),str([r.stderr for r in results])
 print('Competing template edits: stale content cannot overwrite the saved version.')
 version=sql(f"select version from public.whatsapp_template_drafts where id='{record}'").stdout.strip()
 journey={'event':'booking_created','template_id':record,'sources':['ota'],'delay_minutes':0,'prepared':True}
 results=race([command('template',{**content,'state':'archived'},version,record),command('journey',journey)])
 assert sum(r.returncode==0 for r in results)==1,str([r.stderr for r in results])
 assert all(r.returncode==0 or '22023'in r.stderr for r in results),str([r.stderr for r in results])
 assert sql(f"select not exists(select 1 from public.whatsapp_guest_journeys j join public.whatsapp_template_drafts t on t.id=j.template_id where j.property_id='{prop}'and j.prepared and t.state='archived')").stdout.strip()=='t'
 assert sql(f"select count(*)from public.messages where property_id='{prop}'").stdout.strip()=='0'
 print('Preparing a journey versus archiving its template remains consistent; no messages queued.')
finally:
 sql(f"begin;delete from public.tenants where id='{tenant}';delete from auth.users where id='{owner}';commit;")
 assert sql(f"select count(*)from private.whatsapp_studio_commands where property_id='{prop}'").stdout.strip()=='0'
 print('Disposable studio fixtures and command records removed.')

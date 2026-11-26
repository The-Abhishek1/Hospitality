"""Loopback-only concurrency checks for bulk housekeeping and number transfers."""
import concurrent.futures
import json
import subprocess
import threading
import uuid

DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,source,target,other,kind,connection=[str(uuid.uuid4())for _ in range(7)]
def sql(q,required=True):
 r=subprocess.run(['psql',DB,'-X','-qAt','-v','ON_ERROR_STOP=1','-c',q],capture_output=True,text=True,timeout=45)
 if required and r.returncode:raise RuntimeError(r.stderr)
 return r

def actor(q,role='authenticated'):
 claims=json.dumps({'sub':owner,'role':role})
 return f"begin;set local role {role};select set_config('request.jwt.claims','{claims}',true);{q};commit;"

def race(queries):
 barrier=threading.Barrier(len(queries))
 def run(q):barrier.wait();return sql(q,False)
 with concurrent.futures.ThreadPoolExecutor(max_workers=len(queries))as pool:return list(pool.map(run,queries))
try:
 sql(f"""begin;insert into auth.users(id,email)values('{owner}','operational-race-{owner}@test.invalid');
 insert into public.tenants(id,name,slug)values('{tenant}','Operational race','race-{tenant}');
 insert into public.properties(id,tenant_id,name,property_type)values('{source}','{tenant}','Old','hotel'),('{target}','{tenant}','New','hotel'),('{other}','{tenant}','Other new','hotel');
 insert into public.tenant_memberships values('{tenant}','{owner}','owner',now());
 insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('{kind}','{tenant}','{source}','Standard',2,100);
 insert into public.accommodation_units(tenant_id,property_id,type_id,name,housekeeping_status)select'{tenant}','{source}','{kind}','Room '||n,'dirty'from generate_series(1,4)n;
 insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,credentials_ref)values('{connection}','{tenant}','{source}','{uuid.uuid4().int%10**18}','12511251125','managed:{source}');
 insert into private.whatsapp_credentials(property_id,credentials_ref,ciphertext)values('{source}','managed:{source}',repeat('a',80));commit;""")
 items=sql(actor(f"select public.inventory_room_selection('{source}')")).stdout.strip().splitlines()[-1]
 request=str(uuid.uuid4())
 results=race([actor(f"select public.inventory_bulk_rooms('{source}','{request}','{items}'::jsonb,'clean')")]*8)
 assert all(r.returncode==0 for r in results),'Identical bulk requests did not resolve consistently'
 assert sql(f"select count(*)from public.inventory_events where property_id='{source}'and action='bulk_clean'").stdout.strip()=='4'
 print('8 identical bulk requests: one audited change per room.')
 items=sql(actor(f"select public.inventory_room_selection('{source}')")).stdout.strip().splitlines()[-1]
 results=race([actor(f"select public.inventory_bulk_rooms('{source}','{uuid.uuid4()}','{items}'::jsonb,'assign','{owner}')")for _ in range(4)])
 assert all(r.returncode==0 for r in results),'Competing room assignment requests failed'
 updated=[json.loads(r.stdout.strip().splitlines()[-1])['updated']for r in results]
 assert sorted(updated)==[0,0,0,4],updated
 assert sql(f"select count(*)from public.tasks where property_id='{source}'").stdout.strip()=='4'
 print('4 competing assignments: one winner, stale selections reported, no duplicate tasks.')
 results=race([actor(f"select public.whatsapp_transfer_commit('{destination}','{source}','{owner}','{connection}',repeat('b',80))",'service_role')for destination in[target,other]])
 assert sum(r.returncode==0 for r in results)==1,'Both destinations acquired the same sender'
 assert all('deadlock detected'not in r.stderr for r in results),'Transfer lock order deadlocked'
 assert sql(f"select count(*)from public.whatsapp_connections where tenant_id='{tenant}'and status='active'").stdout.strip()=='1'
 print('2 competing sender transfers: exactly one active destination.')
finally:
 sql(f"begin;delete from public.whatsapp_default_templates where property_id in(select id from public.properties where tenant_id='{tenant}');delete from public.whatsapp_default_setup where property_id in(select id from public.properties where tenant_id='{tenant}');delete from public.tenants where id='{tenant}';delete from auth.users where id='{owner}';commit;")
 print('Synthetic operational race fixtures removed.')

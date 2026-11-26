"""Loopback-only races for business deletion and its independent hotel cleanups."""
import concurrent.futures
import subprocess
import uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
admin,tenant,hotel1,hotel2,job=[str(uuid.uuid4())for _ in range(5)]
def sql(query,required=True):
 r=subprocess.run(['psql',DB,'-X','-qAt','-v','ON_ERROR_STOP=1','-c',query],capture_output=True,text=True,timeout=45)
 if required and r.returncode:raise RuntimeError(r.stderr)
 return r

def begin(request):return f"select public.platform_business_deletion_begin('{tenant}','{admin}','{request}',1,'Business race','Synthetic local business race cleanup')"
def step():return f"select public.platform_business_deletion_step('{job}','{admin}')"
try:
 sql(f"""begin;insert into auth.users(id,email)values('{admin}','business-race-{admin}@test.invalid');
 insert into public.platform_admins values('{admin}');insert into public.tenants(id,name,slug)values('{tenant}','Business race','br-{tenant}');
 insert into public.properties(id,tenant_id,name,property_type)values('{hotel1}','{tenant}','Race Hotel A','hotel'),('{hotel2}','{tenant}','Race Hotel B','hotel');commit;""")
 process=subprocess.Popen(['psql',DB,'-X','-qAt','-v','ON_ERROR_STOP=1','-c',f'begin;{begin(job)};select pg_sleep(1);commit;'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 assert process.stdout.readline().strip()==job
 created=sql(f"insert into public.properties(tenant_id,name,property_type)values('{tenant}','Must not escape','hotel')",False)
 process.communicate(timeout=20)
 assert process.returncode==0 and created.returncode!=0,'Hotel creation escaped the business freeze'
 print('PASS A competing hotel creation waits, then fails after the business freeze.')
 with concurrent.futures.ThreadPoolExecutor(max_workers=6)as pool:results=list(pool.map(sql,[begin(str(uuid.uuid4()))for _ in range(6)]))
 assert all(r.stdout.strip()==job for r in results)
 assert sql(f"select count(*)from private.business_deletions where tenant_id='{tenant}'").stdout.strip()=='1'
 print('PASS Concurrent begin requests converge on one business deletion job.')
 hotel_jobs=sql(f"select id from private.hotel_deletions where tenant_id='{tenant}'").stdout.strip().splitlines()
 queries=[step()]*6+[f"select public.platform_hotel_deletion_step('{hotel_job}','{admin}')"for hotel_job in hotel_jobs]
 with concurrent.futures.ThreadPoolExecutor(max_workers=8)as pool:results=list(pool.map(sql,queries))
 assert all('complete'in r.stdout or 'hotels'in r.stdout for r in results)
 assert sql(f"select count(*)from public.tenants where id='{tenant}'").stdout.strip()=='0'
 assert sql(f"select count(*)from public.platform_audit_logs where action='platform_business_deleted'and details->>'business_id'='{tenant}'").stdout.strip()=='1'
 print('PASS Concurrent business and hotel completions remove the account once with one receipt.')
finally:
 sql(f"""begin;delete from public.tenants where id='{tenant}';delete from public.platform_audit_logs where actor_id='{admin}';delete from private.hotel_deletions where tenant_id='{tenant}';delete from private.business_deletions where tenant_id='{tenant}';delete from auth.users where id='{admin}';commit;""")

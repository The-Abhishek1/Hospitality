"""Local-only review races. Disposable hotel, no OTA calls, messages or financial postings."""
import concurrent.futures,json,subprocess,threading,uuid
DB='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
owner,tenant,prop,kind,unit=[str(uuid.uuid4()) for _ in range(5)]
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
def command(case,version,action,request=None,reason='Verified with the provider'):
 details={'reason':reason}
 if action!='retry':details['confirmed']=True
 return f"select public.channel_review_command('{prop}','{case}',{version},'{request or uuid.uuid4()}','{action}','{json.dumps(details)}')"
try:
 sql(f"begin;insert into auth.users(id,email)values('{owner}','review-race-{owner}@test.invalid');insert into public.tenants(id,name,slug)values('{tenant}','Channel review race','review-race-{tenant}');insert into public.tenant_memberships(tenant_id,user_id,role)values('{tenant}','{owner}','owner');insert into public.properties(id,tenant_id,name,property_type)values('{prop}','{tenant}','Review race hotel','hotel');insert into public.accommodation_types(id,tenant_id,property_id,name,max_occupancy,base_rate)values('{kind}','{tenant}','{prop}','Double',2,100);insert into public.accommodation_units(id,tenant_id,property_id,type_id,name)values('{unit}','{tenant}','{prop}','{kind}','101');commit;")
 sql(actor(f"select public.prepare_channel('{prop}','agoda','123','test')"))
 conn=sql(f"select id from public.channel_connections where property_id='{prop}'").stdout.strip()
 sql(f"select public.approve_channel_sandbox('{conn}')")
 def event(key,booking):
  sql(f"begin;select public.ingest_channel_event('{conn}','{key}',jsonb_build_object('type','agoda.snapshot','external_property_id','123','external_reservation_id','{booking}','revision','2026-11-17T01:00:00Z','status','ConfirmBooking','currency','INR','payment_model','property_collect','total_amount','200.00','room_count',1,'external_room_id','456','check_in',current_date+30,'check_out',current_date+32,'adults',2,'children',0));select private.process_channel_event((select id from public.channel_events where connection_id='{conn}'and external_event_id='{key}'));commit;")
  return sql(f"select id from public.channel_review_cases where connection_id='{conn}'and external_reservation_id='{booking}'").stdout.strip()
 case=event('first','9001')
 retry=actor(command(case,1,'retry',str(uuid.uuid4()),'Corrected the room mapping'))
 results=race([retry]*6)
 assert all(r.returncode==0 for r in results),[r.stderr for r in results]
 assert sql(f"select count(*)from public.channel_review_actions where property_id='{prop}'").stdout.strip()=='1'
 print('6 simultaneous retries: one audited command.')
 # Same case version, distinct resolutions: only one can commit.
 version=sql(f"select version from public.channel_review_cases where id='{case}'").stdout.strip()
 results=race([actor(command(case,version,'resolve_manual',reason='Handled directly with provider A')),actor(command(case,version,'resolve_manual',reason='Handled directly with provider B'))])
 assert sum(r.returncode==0 for r in results)==1,[r.stderr for r in results]
 assert all(r.returncode==0 or '40001'in r.stderr for r in results),[r.stderr for r in results]
 print('Competing resolutions: one winner, stale version rejected.')
 # A second failed case: corrected mapping makes the worker eligible to import.
 case2=event('second','9002')
 sql(actor(f"select public.map_channel_room('{conn}','{kind}','456')"))
 event_id=sql(f"select id from public.channel_events where connection_id='{conn}'and external_event_id='second'").stdout.strip()
 sql(f"update public.channel_events set status='received',next_attempt_at=now()where id='{event_id}'")
 worker=f"begin;set local lock_timeout='5s';select private.process_channel_event('{event_id}');commit;"
 results=race([worker,actor(command(case2,1,'resolve_manual'))])
 assert results[0].returncode==0,results[0].stderr
 assert results[1].returncode==0 or '40001'in results[1].stderr,results[1].stderr
 mode=sql(f"select management_mode from public.channel_review_cases where id='{case2}'").stdout.strip()
 count=int(sql(f"select count(*)from public.reservations where property_id='{prop}'and channel_ref='agoda:9002'").stdout.strip())
 assert count==(0 if mode=='manual'else 1),(mode,count)
 assert sql(f"select count(*)from public.folios where property_id='{prop}'").stdout.strip()=='0'
 print('Worker versus manual resolution: consistent handling mode, at most one reservation, no financial postings.')
finally:
 sql(f"begin;delete from public.tenants where id='{tenant}';delete from auth.users where id='{owner}';commit;")
 print('Disposable review fixtures removed.')

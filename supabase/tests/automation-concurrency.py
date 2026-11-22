# Local-only synthetic queue race test. No provider calls or WhatsApp sends.
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4
import subprocess,json
ids={k:str(uuid4())for k in ['tenant','property','guest','stay','connection','conversation','template','rule']}
url='postgresql://postgres:postgres@127.0.0.1:54322/postgres'
def sql(q):
 r=subprocess.run(['psql',url,'-v','ON_ERROR_STOP=1','-X','-Atqc',q],text=True,capture_output=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return r.stdout.strip()
x=ids
try:
 sql(f"""begin;
 insert into public.tenants(id,name,slug)values('{x['tenant']}','Automation race fixture','auto-race-{x['tenant'][:8]}');
 insert into public.properties(id,tenant_id,name,property_type)values('{x['property']}','{x['tenant']}','Race Hotel','hotel');
 insert into public.guests(id,tenant_id,full_name,phone)values('{x['guest']}','{x['tenant']}','Race guest','+919888777666');
 insert into public.reservations(id,tenant_id,property_id,guest_id,check_in,check_out,total_amount,currency)values('{x['stay']}','{x['tenant']}','{x['property']}','{x['guest']}',current_date,current_date+2,100,'INR');
 insert into public.whatsapp_connections(id,tenant_id,property_id,phone_number_id,waba_id,credentials_ref)values('{x['connection']}','{x['tenant']}','{x['property']}','race-{x['connection']}','race-waba','race-no-token');
 insert into public.conversations(id,tenant_id,property_id,connection_id,wa_contact_id,guest_id)values('{x['conversation']}','{x['tenant']}','{x['property']}','{x['connection']}','919888777666','{x['guest']}');
 insert into public.whatsapp_guest_authorizations(property_id,tenant_id,guest_id,wa_contact_id,conversation_id,status,evidence)values('{x['property']}','{x['tenant']}','{x['guest']}','919888777666','{x['conversation']}','granted','Synthetic test permission');
 insert into public.message_templates(id,tenant_id,property_id,name,language,body,status,automation_supported,provider_waba_id,provider_fingerprint,provider_checked_at)values('{x['template']}','{x['tenant']}','{x['property']}','race_static','en_US','Welcome to the hotel.','approved',true,'race-waba','race-revision',now());
 insert into public.whatsapp_automation_rules(id,property_id,tenant_id,event_key,enabled,template_id,template_fingerprint)values('{x['rule']}','{x['property']}','{x['tenant']}','checked_in',true,'{x['template']}','race-revision');
 update public.reservations set status='checked_in'where id='{x['stay']}';commit;""")
 with ThreadPoolExecutor(max_workers=6)as pool:list(pool.map(lambda _:sql("select public.dispatch_whatsapp_automations(50,'https://guest.test')"),range(6)))
 assert sql(f"select count(*)from public.messages where property_id='{x['property']}'and automation_event_id is not null")=='1'
 with ThreadPoolExecutor(max_workers=6)as pool:rows=list(pool.map(lambda _:sql("select message_id from public.claim_outbound_messages_v4(10,false,true)"),range(6)))
 mid=sql(f"select id from public.messages where property_id='{x['property']}'and automation_event_id is not null")
 assert sum(mid in row.splitlines()for row in rows)==1
 sql(f"update public.whatsapp_automation_rules set enabled=false,version=version+1 where id='{x['rule']}'")
 assert sql(f"select public.validate_outbound_claim(id,attempts)->>'ok'from public.messages where id='{mid}'")=='false'
 print('PASS: six dispatchers create one message; six workers claim it once; pausing invalidates the claimed delivery.')
finally:
 if sql(f"select count(*)from public.tenants where id='{x['tenant']}'")=='1':sql(f"delete from public.tenants where id='{x['tenant']}'")

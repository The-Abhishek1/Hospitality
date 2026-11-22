// Scheduled, authenticated queue consumer. No browser invocation and no campaign expansion.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { decryptToken } from '../_shared/whatsapp-crypto.js';
import { fetchTemplates } from '../_shared/whatsapp-templates.js';
import { send, DeliveryError, type SendJob } from '../_shared/whatsapp-transport.ts';
const secret=Deno.env.get('WHATSAPP_WORKER_SECRET')??'';
function authorized(value:string){if(!secret||value.length!==secret.length)return false;let diff=0;for(let i=0;i<secret.length;i++)diff|=secret.charCodeAt(i)^value.charCodeAt(i);return diff===0;}
Deno.serve(async req=>{
 if(req.method!=='POST')return new Response('method not allowed',{status:405});
 if(!authorized(req.headers.get('x-worker-secret')??''))return new Response('forbidden',{status:403});
 const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}}),started=Date.now();
 const graph=Deno.env.get('WHATSAPP_GRAPH_URL')??'https://graph.facebook.com/v27.0';
 const automations=Deno.env.get('WHATSAPP_AUTOMATIONS_ENABLED')==='true';
 const manual:Record<string,string>=JSON.parse(Deno.env.get('WHATSAPP_TOKENS_JSON')??'{}');
 const credential=async(ref:string)=>{if(!ref.startsWith('managed:'))return manual[ref];const r=await db.rpc('whatsapp_delivery_credential',{p_reference:ref});if(r.error||!r.data)throw Error('Authorization unavailable');return decryptToken(r.data,ref,Deno.env.get('WHATSAPP_ENCRYPTION_KEY'));};
 type Job=SendJob&{message_id:string;attempt:number};
 const complete=async(job:Job,id:string|null,error?:DeliveryError)=>{const r=await db.rpc('complete_outbound_message_v2',{p_id:job.message_id,p_attempt:job.attempt,p_ok:Boolean(id),p_wa_id:id,p_error:error?.message.slice(0,500)??null,p_retryable:error?.retryable??false,p_uncertain:error?.uncertain??false});if(r.error||!r.data)throw Error('Completion not recorded');};
 let processed=0,ok=true;
 await db.rpc('record_whatsapp_worker_health',{p_stage:'started'});
 try{
  if(automations){
   // Sync at most one due hotel per invocation; a failed hotel does not starve the rest.
   const due=await db.from('whatsapp_connections').select('id,waba_id,credentials_ref').eq('status','active').lte('templates_sync_after',new Date().toISOString()).order('templates_sync_after').limit(1);
   const c=due.data?.[0];if(c){try{const token=await credential(c.credentials_ref);if(!token)throw Error('Missing authorization');const deadline=AbortSignal.timeout(35000);
    const templates=await fetchTemplates(c.waba_id,token,graph.split('/').at(-1)!,((url:RequestInfo|URL,options?:RequestInit)=>fetch(url,{...options,signal:AbortSignal.any([deadline,...(options?.signal?[options.signal]:[])])}))as typeof fetch);
    const synced=await db.rpc('sync_whatsapp_provider_templates',{p_connection:c.id,p_waba:c.waba_id,p_templates:templates});if(synced.error)throw synced.error;
   }catch{await db.from('whatsapp_connections').update({templates_sync_after:new Date(Date.now()+5*60*1000).toISOString()}).eq('id',c.id);console.error('Provider template sync unavailable',c.id);}}
   const dispatch=await db.rpc('dispatch_whatsapp_automations',{p_limit:50,p_portal_origin:Deno.env.get('GUEST_PORTAL_URL')??null});if(dispatch.error)throw dispatch.error;
  }
  // Claim one message at a time so a bounded invocation never abandons a whole batch.
  while(processed<20&&Date.now()-started<85000){
   const jobs=await db.rpc('claim_outbound_messages_v4',{p_limit:1,p_allow_campaigns:false,p_allow_automations:automations});if(jobs.error)throw jobs.error;const job=jobs.data?.[0]as Job|undefined;if(!job)break;
   const valid=await db.rpc('validate_outbound_claim',{p_id:job.message_id,p_attempt:job.attempt});
   if(valid.error)throw valid.error;
   if(!valid.data?.ok){await complete(job,null,new DeliveryError(valid.data?.error??'Message no longer eligible'));processed++;continue;}
   let token:string|undefined;try{token=await credential(job.credentials_ref);}catch{await complete(job,null,new DeliveryError('Secure authorization unavailable. Reconnect WhatsApp.'));processed++;continue;}
   let id:string;
   try{id=await send(job,token,graph);}catch(e){await complete(job,null,e instanceof DeliveryError?e:new DeliveryError('Delivery outcome unknown. Reconcile provider status.',false,true));processed++;continue;}
   // A provider success followed by a DB failure must never be interpreted as a send rejection.
   try{await complete(job,id);}catch{console.error('Provider accepted a message but completion was not recorded',job.message_id);ok=false;}
   processed++;
  }
 }catch{ok=false;console.error('Scheduled WhatsApp queue processing failed');}
 await db.rpc('record_whatsapp_worker_health',{p_stage:'finished',p_ok:ok});
 return Response.json({ok,processed},{status:ok?200:500});
});

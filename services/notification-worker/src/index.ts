// Official WhatsApp queue worker. UI replies are queued; only this process sends.
import {createClient} from '@supabase/supabase-js';
import {send,DeliveryError} from './transport.js';
import {decryptToken} from '../../../packages/whatsapp-security/index.mjs';
import {fetchTemplates} from '../../../packages/whatsapp-security/templates.mjs';
const db=createClient(process.env.SUPABASE_URL!,process.env.SUPABASE_SERVICE_ROLE_KEY!,{auth:{persistSession:false}});
const tokens:Record<string,string>=JSON.parse(process.env.WHATSAPP_TOKENS_JSON??'{}');
const GRAPH=process.env.WHATSAPP_GRAPH_URL??'https://graph.facebook.com/v27.0';
type Job={message_id:string;phone_number_id:string;credentials_ref:string;wa_contact_id:string;msg_type:string;msg_body:string|null;template_name:string|null;template_language:string|null;attempt:number;template_components?:unknown[]|null;outbound_payload?:Record<string,unknown>|null};
async function credential(ref:string){
 if(!ref.startsWith('managed:'))return tokens[ref];
 const {data,error}=await db.rpc('whatsapp_delivery_credential',{p_reference:ref});if(error||!data)throw Error('Authorization unavailable');
 return decryptToken(data,ref,process.env.WHATSAPP_ENCRYPTION_KEY);
}
let nextTemplateSync=0;
async function syncTemplates(){
 if(Date.now()<nextTemplateSync)return;nextTemplateSync=Date.now()+15*60*1000;
 const {data,error}=await db.from('whatsapp_connections').select('id,waba_id,credentials_ref').eq('status','active');if(error)throw error;
 for(const c of data??[]){try{const token=await credential(c.credentials_ref);if(!token)continue;
  const templates=await fetchTemplates(c.waba_id,token,GRAPH.split('/').at(-1)!);
  const r=await db.rpc('sync_whatsapp_provider_templates',{p_connection:c.id,p_waba:c.waba_id,p_templates:templates});if(r.error)throw Error('Could not persist templates');
 }catch{console.error('Template synchronization failed for connection',c.id);}}
}
async function complete(job:Job,ok:boolean,id:string|null,error?:DeliveryError){
 const {data,error:rpcError}=await db.rpc('complete_outbound_message_v2',{p_id:job.message_id,p_attempt:job.attempt,p_ok:ok,p_wa_id:id,p_error:error?.message.slice(0,500)??null,p_retryable:error?.retryable??false,p_uncertain:error?.uncertain??false});
 if(rpcError)throw rpcError;if(!data)throw new Error(`Completion rejected for expired message claim ${job.message_id}; verify provider delivery.`);
}
async function tick():Promise<number>{
 const campaignsEnabled=process.env.WHATSAPP_CAMPAIGNS_ENABLED==='true';
 const automationsEnabled=process.env.WHATSAPP_AUTOMATIONS_ENABLED==='true';
 if(automationsEnabled){await syncTemplates();const {error}=await db.rpc('dispatch_whatsapp_automations',{p_limit:50,p_portal_origin:process.env.GUEST_PORTAL_URL??null});if(error)throw error;}
 if(campaignsEnabled){const {error:dispatchError}=await db.rpc('dispatch_whatsapp_campaigns',{p_limit:50});if(dispatchError)throw dispatchError;}
 const concierge=await db.rpc('dispatch_whatsapp_guest_replies',{p_limit:50,p_portal_origin:process.env.GUEST_PORTAL_URL??null});if(concierge.error)throw concierge.error;
 const {data,error}=await db.rpc('claim_outbound_messages_v5',{p_limit:10,p_allow_campaigns:campaignsEnabled,p_allow_automations:automationsEnabled});if(error)throw error;
 const jobs=(data??[]) as Job[];
 for(const job of jobs){
  // An RPC/acknowledgment failure must not be treated as a failed HTTP send.
  const {data:check,error:checkError}=await db.rpc('validate_outbound_claim',{p_id:job.message_id,p_attempt:job.attempt});
  if(checkError){console.error('Cannot validate message claim',job.message_id,checkError);continue;}
  if(!check?.ok){try{await complete(job,false,null,new DeliveryError(check?.error??'Claim is no longer eligible.'));}catch(e){console.error('Cannot record ineligible message',job.message_id,e);}continue;}
  let id:string;
  let token:string|undefined;
  try{token=await credential(job.credentials_ref);}catch{try{await complete(job,false,null,new DeliveryError('Secure authorization unavailable. Reconnect WhatsApp before retrying.'));}catch{console.error('Cannot record missing authorization',job.message_id);}continue;}
  try{id=await send(job,token,GRAPH);}catch(e){const failure=e instanceof DeliveryError?e:new DeliveryError('Unexpected delivery error; verify outcome before resending.',false,true);try{await complete(job,false,null,failure);}catch(ack){console.error('Cannot save delivery failure',job.message_id,ack);}continue;}
  try{await complete(job,true,id);}catch(e){console.error('Message accepted by provider but completion was not recorded',job.message_id,id,e);}
 }
 return jobs.length;
}
for(;;){try{if(await tick()>0)continue;}catch(e){console.error('Queue tick failed',e);}await new Promise(r=>setTimeout(r,2000));}

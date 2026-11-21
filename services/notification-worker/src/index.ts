// Official WhatsApp queue worker. UI replies are queued; only this process sends.
import {createClient} from '@supabase/supabase-js';
import {send,DeliveryError} from './transport.js';
import {decryptToken} from '../../../packages/whatsapp-security/index.mjs';
const db=createClient(process.env.SUPABASE_URL!,process.env.SUPABASE_SERVICE_ROLE_KEY!,{auth:{persistSession:false}});
const tokens:Record<string,string>=JSON.parse(process.env.WHATSAPP_TOKENS_JSON??'{}');
const GRAPH=process.env.WHATSAPP_GRAPH_URL??'https://graph.facebook.com/v21.0';
type Job={message_id:string;phone_number_id:string;credentials_ref:string;wa_contact_id:string;msg_type:string;msg_body:string|null;template_name:string|null;template_language:string|null;attempt:number};
async function complete(job:Job,ok:boolean,id:string|null,error?:DeliveryError){
 const {data,error:rpcError}=await db.rpc('complete_outbound_message_v2',{p_id:job.message_id,p_attempt:job.attempt,p_ok:ok,p_wa_id:id,p_error:error?.message.slice(0,500)??null,p_retryable:error?.retryable??false,p_uncertain:error?.uncertain??false});
 if(rpcError)throw rpcError;if(!data)throw new Error(`Completion rejected for expired message claim ${job.message_id}; verify provider delivery.`);
}
async function tick():Promise<number>{
 const campaignsEnabled=process.env.WHATSAPP_CAMPAIGNS_ENABLED==='true';
 if(campaignsEnabled){const {error:dispatchError}=await db.rpc('dispatch_whatsapp_campaigns',{p_limit:50});if(dispatchError)throw dispatchError;}
 const {data,error}=await db.rpc('claim_outbound_messages_v3',{p_limit:10,p_allow_campaigns:campaignsEnabled});if(error)throw error;
 const jobs=(data??[]) as Job[];
 for(const job of jobs){
  // An RPC/acknowledgment failure must not be treated as a failed HTTP send.
  const {data:check,error:checkError}=await db.rpc('validate_outbound_claim',{p_id:job.message_id,p_attempt:job.attempt});
  if(checkError){console.error('Cannot validate message claim',job.message_id,checkError);continue;}
  if(!check?.ok){try{await complete(job,false,null,new DeliveryError(check?.error??'Claim is no longer eligible.'));}catch(e){console.error('Cannot record ineligible message',job.message_id,e);}continue;}
  let id:string;
  let token=tokens[job.credentials_ref];
  if(job.credentials_ref.startsWith('managed:')){
   try{const {data,error}=await db.rpc('whatsapp_delivery_credential',{p_reference:job.credentials_ref});if(error||!data)throw Error('Unavailable');token=decryptToken(data,job.credentials_ref,process.env.WHATSAPP_ENCRYPTION_KEY);}
   catch{try{await complete(job,false,null,new DeliveryError('Secure authorization unavailable. Reconnect WhatsApp before retrying.'));}catch{console.error('Cannot record missing authorization',job.message_id);}continue;}
  }
  try{id=await send(job,token,GRAPH);}catch(e){const failure=e instanceof DeliveryError?e:new DeliveryError('Unexpected delivery error; verify outcome before resending.',false,true);try{await complete(job,false,null,failure);}catch(ack){console.error('Cannot save delivery failure',job.message_id,ack);}continue;}
  try{await complete(job,true,id);}catch(e){console.error('Message accepted by provider but completion was not recorded',job.message_id,id,e);}
 }
 return jobs.length;
}
for(;;){try{if(await tick()>0)continue;}catch(e){console.error('Queue tick failed',e);}await new Promise(r=>setTimeout(r,2000));}

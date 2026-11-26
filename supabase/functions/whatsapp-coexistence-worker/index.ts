import {createClient} from 'npm:@supabase/supabase-js@2';
import {decryptToken} from '../_shared/whatsapp-crypto.js';
import {coexistenceBatch,requestCoexistenceSync} from '../_shared/whatsapp-coexistence.js';
const secret=Deno.env.get('WHATSAPP_WORKER_SECRET')??'';
function authorized(input:string){if(!secret||input.length!==secret.length)return false;let diff=0;for(let i=0;i<secret.length;i++)diff|=secret.charCodeAt(i)^input.charCodeAt(i);return diff===0;}
Deno.serve(async req=>{
 if(req.method!=='POST')return new Response('method not allowed',{status:405});
 if(!authorized(req.headers.get('x-worker-secret')??''))return new Response('forbidden',{status:403});
 const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}}),start=Date.now();let batches=0,requests=0;
 try{
  // Start mandatory one-time data requests promptly; reconnect never resubmits accepted requests.
  for(let i=0;i<2;i++){
   const claimed=await db.rpc('claim_whatsapp_coexistence_sync');if(claimed.error)throw Error();const job=claimed.data;if(!job)break;
   let result:{state:string;request?:string}={state:'failed'};
   try{
    const saved=await db.rpc('whatsapp_delivery_credential',{p_reference:job.reference});if(saved.error||!saved.data)throw Error();
    const token=decryptToken(saved.data,job.reference,Deno.env.get('WHATSAPP_ENCRYPTION_KEY'));
    result=await requestCoexistenceSync({phone:job.phone,kind:job.kind,token,version:(Deno.env.get('WHATSAPP_GRAPH_URL')??'https://graph.facebook.com/v27.0').split('/').at(-1)});
   }catch{/* No credential values or provider response bodies are logged. */}
   const done=await db.rpc('finish_whatsapp_coexistence_sync',{p_connection:job.connection_id,p_kind:job.kind,p_lease:job.lease,p_state:result.state,p_request:result.request??null});if(done.error)throw Error();requests++;
  }
  while(Date.now()-start<80000&&batches<30){
   const claimed=await db.rpc('claim_whatsapp_coexistence_event');if(claimed.error)throw Error();const job=claimed.data;if(!job)break;
   let offset=job.cursor,complete=false;
   try{do{
    const batch=coexistenceBatch(job.field,job.payload,offset,200);
    const r=await db.rpc('apply_whatsapp_coexistence_batch',{p_event:job.id,p_lease:job.lease,p_offset:offset,p_records:batch.records,p_next:batch.next,p_done:batch.done,p_summary:batch.summary});if(r.error)throw Error();
    offset=r.data;batches++;if(batch.done){complete=true;break;}
   }while(Date.now()-start<80000&&batches<30);
   if(!complete){const released=await db.rpc('release_whatsapp_coexistence_event',{p_event:job.id,p_lease:job.lease});if(released.error)throw Error();}
   }catch{await db.rpc('release_whatsapp_coexistence_event',{p_event:job.id,p_lease:job.lease,p_failed:true});throw Error();}
  }
  return Response.json({ok:true,batches,requests});
 }catch{return Response.json({ok:false,batches,requests},{status:500});}
});

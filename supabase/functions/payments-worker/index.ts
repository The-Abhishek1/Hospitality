import {createClient} from 'npm:@supabase/supabase-js@2';
import {decryptToken} from '../_shared/whatsapp-crypto.js';
import {client} from '../_shared/razorpay.js';
const secret=Deno.env.get('PAYMENTS_WORKER_SECRET')??Deno.env.get('WHATSAPP_WORKER_SECRET')??'';
function authorized(value:string){if(!secret||value.length!==secret.length)return false;let diff=0;for(let i=0;i<secret.length;i++)diff|=secret.charCodeAt(i)^value.charCodeAt(i);return diff===0;}
Deno.serve(async(req:Request)=>{
 if(req.method!=='POST')return new Response('method not allowed',{status:405});
 if(!authorized(req.headers.get('x-worker-secret')??''))return new Response('forbidden',{status:403});
 const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}}),started=Date.now();let processed=0,ok=true;
 while(processed<5&&Date.now()-started<65000){
  const claim=await db.rpc('claim_online_payment');if(claim.error){ok=false;break;}const job=claim.data;if(!job)break;
  try{
   const credentials=JSON.parse(decryptToken(job.credential,'razorpay:'+job.connection_id,Deno.env.get('PAYMENTS_ENCRYPTION_KEY')??Deno.env.get('WHATSAPP_ENCRYPTION_KEY')));
   const snapshot=await client(credentials.keyId,credentials.keySecret).process(job),result=await db.rpc('apply_online_payment',{p_request:job.id,p_lease:job.lease,p_snapshot:snapshot});if(result.error)throw Error('Payment accounting could not be completed. Reconciliation is required.');
  }catch{ok=false;await db.rpc('fail_online_payment',{p_request:job.id,p_lease:job.lease,p_error:'Payment check could not be completed. Verify the account and reconcile this request. No duplicate payment link will be created.'});}
  processed++;
 }
 await db.rpc('record_payment_worker_health',{p_ok:ok});return Response.json({ok,processed},{status:ok?200:500});
});

import {NextRequest,NextResponse} from 'next/server';
import {randomBytes,randomUUID} from 'node:crypto';
import {createClient} from '@/lib/supabase/server';
import {backend} from '@/lib/whatsapp-onboarding';
import {validId} from '@/lib/reservations';
import {encryptToken,decryptToken} from '../../../../../../../../packages/whatsapp-security/index.mjs';
import {client,validKeys} from '../../../../../../../../packages/razorpay/index.mjs';
export const runtime='nodejs';export const maxDuration=60;
const result=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'private, no-store'}});
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 if(req.headers.get('origin')!==(process.env.APP_URL||req.nextUrl.origin).replace(/\/$/,''))return result({error:'Open the configured hotel app address.'},403);
 const{propertyId:pid}=await params;if(!validId(pid))return result({error:'Hotel not found.'},404);
 if(Number(req.headers.get('content-length'))>8192)return result({error:'Request is too large.'},413);
 const db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return result({error:'Sign in again.'},401);
 const{data:workspace,error}=await db.rpc('payment_workspace',{p_property:pid});if(error||!workspace?.can_configure)return result({error:'Hotel administrator access required.'},403);
 const master=process.env.PAYMENTS_ENCRYPTION_KEY||process.env.WHATSAPP_ENCRYPTION_KEY;if(!/^[a-f0-9]{64}$/i.test(master??''))return result({error:'The platform payment encryption key is not configured.'},503);
 try{
  const input=await req.json();
  if(input.action==='webhook_secret'){
   if(input.connection!==workspace.connection?.id)return result({error:'Active connection not found.'},404);
   const{data,error}=await backend().rpc('payment_credential',{p_connection:input.connection});if(error||!data)return result({error:'Connection unavailable.'},404);
   const credentials=JSON.parse(decryptToken(data.ciphertext,'razorpay:'+input.connection,master));return result({webhookSecret:credentials.webhookSecret});
  }
  if(input.action!=='connect')return result({error:'Choose a valid connection action.'},400);
  if(String(input.keyId??'').startsWith('rzp_test_')&&input.testHotel!==true)return result({error:'Confirm this is a dedicated test hotel. Test payments do not collect money.'},400);
  const keyId=String(input.keyId??'').trim(),keySecret=String(input.keySecret??'').trim();if(!['test','live'].includes(input.mode)||!keyId.startsWith(`rzp_${input.mode}_`)||input.mode==='live'&&input.liveConfirmed!==true)return result({error:'Choose the matching account mode and confirm Live Mode before connecting real payments.'},400);if(!validKeys(keyId,keySecret))return result({error:'Enter this hotel’s Razorpay Key ID and Key Secret.'},400);
  await client(keyId,keySecret).verify();
  const id=randomUUID(),ciphertext=encryptToken(JSON.stringify({keyId,keySecret,webhookSecret:randomBytes(32).toString('hex')}),'razorpay:'+id,master);
  const saved=await backend().rpc('payment_connection_commit',{p_property:pid,p_actor:user.id,p_connection:id,p_key_hint:(keyId.startsWith('rzp_live_')?'rzp_live_…':'rzp_test_…')+keyId.slice(-4),p_ciphertext:ciphertext,p_test_hotel:input.testHotel===true});
  if(saved.error)return result({error:['22023','42501'].includes(saved.error.code)?saved.error.message:'Connection could not be saved.'},400);
  return result({success:'Account connected. Configure its webhook, then enable online payments.'});
 }catch(error){return result({error:error instanceof Error&&error.name==='PaymentError'?error.message:'Could not complete payment setup. Verify the account mode and keys, then try again.'},400);}
}

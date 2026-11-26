import {NextResponse} from 'next/server';
import {createHash,createHmac,timingSafeEqual} from 'node:crypto';
import {backend} from '@/lib/whatsapp-onboarding';
import {validId} from '@/lib/reservations';
import {decryptToken} from '../../../../../../../../../packages/whatsapp-security/index.mjs';
export const runtime='nodejs';export const maxDuration=60;
export async function POST(req:Request,{params}:{params:Promise<{connectionId:string}>}){
 const{connectionId:id}=await params,reply=(status:number,message:string)=>NextResponse.json({message},{status,headers:{'Cache-Control':'no-store'}});
 if(!validId(id))return reply(400,'Invalid webhook.');
 if(Number(req.headers.get('content-length'))>1_000_000)return reply(413,'Webhook too large.');
 const signature=req.headers.get('x-razorpay-signature')??'';if(!/^[a-f0-9]{64}$/i.test(signature))return reply(401,'Webhook authorization failed.');
 try{
  const db=backend(),{data,error}=await db.rpc('payment_credential',{p_connection:id});if(error||!data)return reply(401,'Webhook authorization failed.');
  const master=process.env.PAYMENTS_ENCRYPTION_KEY||process.env.WHATSAPP_ENCRYPTION_KEY,credentials=JSON.parse(decryptToken(data.ciphertext,'razorpay:'+id,master));
  const chunks:Uint8Array[]=[];let size=0;const reader=req.body?.getReader();if(!reader)return reply(400,'Invalid webhook body.');
  while(true){const next=await reader.read();if(next.done)break;size+=next.value.length;if(size>1_000_000){await reader.cancel();return reply(413,'Webhook too large.');}chunks.push(next.value);}
  const raw=Buffer.concat(chunks),expected=createHmac('sha256',credentials.webhookSecret).update(raw).digest();
  if(!timingSafeEqual(expected,Buffer.from(signature,'hex')))return reply(401,'Webhook authorization failed.');
  const event=JSON.parse(raw.toString('utf8'));if(!['payment_link.paid','payment_link.expired','payment_link.cancelled','payment.captured','payment.failed','refund.processed'].includes(event.event))return reply(200,'Ignored event.');
  const link=event.payload?.payment_link?.entity,payment=event.payload?.payment?.entity,refund=event.payload?.refund?.entity;
  const hash=createHash('sha256').update(raw).digest('hex'),eventId=req.headers.get('x-razorpay-event-id')||hash;
  const value=(s:unknown)=>typeof s==='string'&&s.length<=100?s:null;
  const notified=await db.rpc('notify_payment_webhook',{p_connection:id,p_event:eventId,p_hash:hash,p_reference:value(link?.reference_id),p_link:value(link?.id),p_order:value(payment?.order_id??link?.order_id),p_payment:value(payment?.id??refund?.payment_id)});
  if(notified.error)return reply(notified.error.code==='22023'?409:503,'Payment reconciliation could not be queued.');
  if(event.event==='payment.failed'){const problem=await db.rpc('record_booking_payment_problem',{p_connection:id,p_event:eventId,p_order:value(payment?.order_id??link?.order_id),p_link:value(link?.id),p_payment:value(payment?.id)});if(problem.error)return reply(503,'Payment update could not be queued.');}
  return reply(200,'Payment check queued.');
 }catch{return reply(503,'Webhook processing unavailable. Retry later.');}
}

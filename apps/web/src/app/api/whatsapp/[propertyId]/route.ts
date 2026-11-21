import{NextRequest,NextResponse}from'next/server';
import{createClient}from'@/lib/supabase/server';
import{backend,onboardingReady,exchangeCode,verifyAuthorization,verifySender,meta,seal,savedToken,SetupError}from'@/lib/whatsapp-onboarding';
export const runtime='nodejs';
export const maxDuration=180;
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 const reply=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'no-store'}});
 // Reject cross-site writes; do not infer trusted origins from caller-supplied forwarded headers.
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return reply({error:'Open this page at the configured onboarding address before continuing.'},403);
 const {propertyId:pid}=await params;
 if(!/^[0-9a-f-]{36}$/i.test(pid))return reply({error:'Invalid hotel.'},400);
 if(Number(req.headers.get('content-length')??0)>20000)return reply({error:'Request too large.'},413);
 const db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return reply({error:'Sign in again.'},401);
 const {data:context,error:denied}=await db.rpc('whatsapp_setup_context',{p_property:pid});
 if(denied)return reply({error:'Hotel administrator access required, or onboarding migration is not installed.'},403);
 try{
  const b=await req.json();
  if(b.action==='disconnect'){
   const {error}=await db.rpc('whatsapp_setup_disconnect',{p_property:pid});if(error)throw new SetupError('Could not disconnect. Refresh and try again.');
   return reply({success:'Disconnected from Hospitality. History is retained. You can also remove Hospitality access in Meta Business Settings.'});
  }
  if(!onboardingReady())return reply({error:'Your platform administrator must finish Meta onboarding configuration first.'},503);
  if(b.action==='begin'){
   const {data,error}=await db.rpc('whatsapp_setup_begin',{p_property:pid});if(error)throw new SetupError('Could not start setup. Refresh and try again.');return reply({session:data});
  }
  if(b.action==='health'){
   const c=context.connection;if(!c||c.status!=='active')throw new SetupError('Connect this hotel’s number first.');
   const token=await savedToken(`managed:${pid}`);await verifyAuthorization(token);const sender=await verifySender(token,c.waba_id,c.phone_number_id),apps=await meta(`${c.waba_id}/subscribed_apps`,token);
   const subscribed=apps.data?.some((x:{whatsapp_business_api_data?:{id:string}})=>x.whatsapp_business_api_data?.id===process.env.WHATSAPP_APP_ID);
   return reply({success:`${sender.display_phone_number}: credentials valid. ${subscribed?'Hospitality webhook subscription confirmed.':'Webhook subscription missing. Reconnect to repair.'} This check does not prove message delivery.`});
  }
  if(b.action!=='complete')return reply({error:'Unknown action.'},400);
  if(!/^[0-9a-f-]{36}$/i.test(b.session??'')||typeof b.code!=='string'||b.code.length<1||b.code.length>8000||!/^\d{5,30}$/.test(b.phone??'')||!/^\d{5,30}$/.test(b.waba??''))return reply({error:'Meta did not return a complete setup. Start again.'},400);
  if(context.connection&&(context.connection.phone_number_id!==b.phone||context.connection.waba_id!==b.waba))throw new SetupError('This hotel already has a sender. Use a separate hotel to test another number; reconnect keeps the same sender and history.');
  const admin=backend(),claimed=await admin.rpc('whatsapp_setup_claim',{p_session:b.session,p_actor:user.id});
  if(claimed.error||claimed.data!==pid)throw new SetupError('Setup expired or was already attempted. Start again.');
  const token=await exchangeCode(b.code);await verifyAuthorization(token);const sender=await verifySender(token,b.waba,b.phone);
  if(sender.code_verification_status!=='VERIFIED')throw new SetupError('Complete phone ownership verification in Meta first.');
  // Existing connections already completed registration; do not reset their two-step PIN.
  if(!context.connection){
   if(!/^\d{6}$/.test(b.pin??''))throw new SetupError('Enter a six-digit two-step verification PIN before connecting.');
   await meta(`${b.phone}/register`,token,'POST',{messaging_product:'whatsapp',pin:b.pin});
  }
  await meta(`${b.waba}/subscribed_apps`,token,'POST');
  const {error}=await admin.rpc('whatsapp_setup_commit',{p_session:b.session,p_actor:user.id,p_phone:b.phone,p_waba:b.waba,p_display:sender.display_phone_number,p_ciphertext:seal(token,pid)});
  if(error)throw new SetupError(error.code==='23505'?'This number is connected to another hotel.':'Could not save the connection. Start again; if Meta registered the number already, keep its existing PIN.');
  return reply({success:'Connected. Send a message from another phone, then open the hotel Inbox to verify delivery.'});
 }catch(e){return reply({error:e instanceof SetupError?e.message:'Connection check failed. Check Meta account settings and try again. No automatic retry was made.'},400);}
}

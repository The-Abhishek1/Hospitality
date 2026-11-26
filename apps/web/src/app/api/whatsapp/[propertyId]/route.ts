import{NextRequest,NextResponse}from'next/server';
import{createClient}from'@/lib/supabase/server';
import{backend,onboardingReady,exchangeCode,verifyAuthorization,verifySender,coexistenceSender,meta,seal,savedToken,SetupError}from'@/lib/whatsapp-onboarding';
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
  if(b.action==='retry_import'){
   if(!['events','history','smb_app_state_sync'].includes(b.kind))throw new SetupError('Choose the failed import to retry.');
   const {error}=await db.rpc('retry_whatsapp_coexistence',{p_property:pid,p_kind:b.kind});if(error)throw new SetupError(error.code==='22023'?error.message:'Could not retry the import.');
   return reply({success:'Import queued. Already recorded messages will not be duplicated.'});
  }
  if(!onboardingReady())return reply({error:'Your platform administrator must finish Meta onboarding configuration first.'},503);
  if(b.action==='begin'){
   if(!['cloud_api','coexistence'].includes(b.mode??'cloud_api'))throw new SetupError('Choose how to connect this number.');
   const {data,error}=await db.rpc('whatsapp_setup_begin_v2',{p_property:pid,p_mode:b.mode??'cloud_api',p_phone:typeof b.phone==='string'?b.phone:null});if(error)throw new SetupError(error.code==='22023'?error.message:'Could not start setup. Refresh and try again.');return reply({session:data});
  }
  if(b.action==='health'){
   const c=context.connection;if(!c||c.status!=='active')throw new SetupError('Connect this hotel’s number first.');
   const token=await savedToken(`managed:${pid}`);await verifyAuthorization(token);const sender=await verifySender(token,c.waba_id,c.phone_number_id),apps=await meta(`${c.waba_id}/subscribed_apps`,token);
   const subscribed=apps.data?.some((x:{whatsapp_business_api_data?:{id:string}})=>x.whatsapp_business_api_data?.id===process.env.WHATSAPP_APP_ID);
   return reply({success:`${sender.display_phone_number}: credentials valid. ${subscribed?'Hospitality webhook subscription confirmed.':'Webhook subscription missing. Reconnect to repair.'} This check does not prove message delivery.`});
  }
  if(b.action!=='complete')return reply({error:'Unknown action.'},400);
  if(!/^[0-9a-f-]{36}$/i.test(b.session??'')||typeof b.code!=='string'||b.code.length<1||b.code.length>8000||(b.phone!=null&&!/^\d{5,30}$/.test(b.phone))||!/^\d{5,30}$/.test(b.waba??''))return reply({error:'Meta did not return a complete setup. Start again.'},400);
  const admin=backend(),claimed=await admin.rpc('whatsapp_setup_claim_v2',{p_session:b.session,p_actor:user.id});
  if(claimed.error||claimed.data?.property_id!==pid)throw new SetupError('Setup expired or was already attempted. Start again.');
  const coexistence=claimed.data.mode==='coexistence';
  if(!coexistence&&!b.phone)throw new SetupError('Meta did not return the phone number ID. Start again.');
  const token=await exchangeCode(b.code);await verifyAuthorization(token);
  const sender=coexistence?await coexistenceSender(token,b.waba,claimed.data.expected_phone,b.phone):await verifySender(token,b.waba,b.phone);
  if(context.connection&&(context.connection.phone_number_id!==sender.id||context.connection.waba_id!==b.waba))throw new SetupError('This hotel already has a sender. Use a separate hotel to test another number; reconnect keeps the same sender and history.');
  if(!coexistence&&sender.code_verification_status!=='VERIFIED')throw new SetupError('Complete phone ownership verification in Meta first.');
  // Existing connections already completed registration; do not reset their two-step PIN.
  if(!coexistence&&!context.connection){
   const state=await meta(`${sender.id}?fields=id,is_on_biz_app`,token);
   if(state.is_on_biz_app===true)throw new SetupError('This number uses the WhatsApp Business app. Start again and choose Keep using WhatsApp Business app.');
   if(!/^\d{6}$/.test(b.pin??''))throw new SetupError('Enter a six-digit two-step verification PIN before connecting.');
   await meta(`${sender.id}/register`,token,'POST',{messaging_product:'whatsapp',pin:b.pin});
  }
  await meta(`${b.waba}/subscribed_apps`,token,'POST');
  const {error}=await admin.rpc('whatsapp_setup_commit',{p_session:b.session,p_actor:user.id,p_phone:sender.id,p_waba:b.waba,p_display:sender.display_phone_number,p_ciphertext:seal(token,pid)});
  if(error)throw new SetupError(error.code==='23505'?'This number is connected to another hotel.':'Could not save the connection. Start again; if Meta registered the number already, keep its existing PIN.');
  if(coexistence){await admin.rpc('wake_whatsapp_coexistence');return reply({success:'Connected alongside the WhatsApp Business app. Keep the phone app open while contacts and permitted history synchronize. Send a fresh guest message to test automation.'});}
  return reply({success:'Connected. Send a message from another phone, then open the hotel Inbox to verify delivery.'});
 }catch(e){return reply({error:e instanceof SetupError?e.message:'Connection check failed. Check Meta account settings and try again. No automatic retry was made.'},400);}
}

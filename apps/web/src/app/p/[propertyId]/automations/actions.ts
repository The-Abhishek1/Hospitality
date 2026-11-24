'use server';
import{createClient}from'@/lib/supabase/server';import{revalidatePath}from'next/cache';import{redirect}from'next/navigation';
import {validId} from '@/lib/reservations';
export type AutomationState={error?:string;success?:string};
export async function saveBookingWelcome(_:AutomationState,fd:FormData):Promise<AutomationState>{
 const pid=String(fd.get('pid')??''),intent=String(fd.get('intent')??'');
 if(!validId(pid)||!['on','off','assign'].includes(intent))return{error:'Refresh the booking welcome before saving.'};
 const db=await createClient(),{data,error}=await db.rpc('whatsapp_automation_workspace',{p_property:pid,p_page:1});
 if(error)return{error:'Hotel administrator access required.'};
 const rule=data.rules?.find((r:{event_key:string})=>r.event_key==='booking_confirmed');
 if((rule?.version??0)!==Number(fd.get('version')))return{error:'The welcome changed. Refresh before saving.'};
 let keys;try{keys=intent==='off'?rule?.parameter_keys??[]:JSON.parse(String(fd.get('keys')??'[]'));}catch{return{error:'Choose a compatible welcome message.'};}
 const{error:saveError}=await db.rpc('save_whatsapp_automation_rule',{p_property:pid,p_event:'booking_confirmed',p_version:rule?.version??0,p_enabled:intent==='on'||intent==='assign'&&Boolean(rule?.enabled),p_template:intent==='off'?rule?.template_id??null:String(fd.get('template')??'')||null,p_keys:keys,p_delay:0});
 if(saveError)return{error:['22023','40001','42501'].includes(saveError.code)?saveError.message:'Could not save the welcome. Refresh and try again.'};
 revalidatePath(`/p/${pid}/automations`);revalidatePath(`/p/${pid}/reservations`);
 return{success:intent==='on'?'Booking welcome is on for new eligible bookings.':intent==='off'?'Booking welcome is off. Guest menu and other event messages are unchanged.':'Welcome message selected. Use the switch to turn automatic sending on or off.'};
}
export async function saveAutomation(_:AutomationState,fd:FormData):Promise<AutomationState>{
 const db=await createClient(),pid=String(fd.get('pid')??''),kind=String(fd.get('kind')??'');let result;
 if(kind==='rule'){
  let keys;try{keys=JSON.parse(String(fd.get('keys')??'[]'));}catch{return{error:'Invalid variable mapping.'};}
  result=await db.rpc('save_whatsapp_automation_rule',{p_property:pid,p_event:String(fd.get('event')),p_version:Number(fd.get('version')),p_enabled:fd.get('enabled')==='on',p_template:String(fd.get('template')??'')||null,p_keys:keys,p_delay:Number(fd.get('delay')??0)});
 }else if(kind==='permission'){
  result=await db.rpc('authorize_whatsapp_stay_updates',{p_property:pid,p_reservation:String(fd.get('reservation')),p_version:Number(fd.get('version')),p_status:String(fd.get('status')),p_evidence:String(fd.get('evidence')??''),p_confirmed:fd.get('confirmed')==='on'});
 }else return{error:'Unknown action.'};
 if(result.error)return{error:['22023','40001','42501','23505'].includes(result.error.code)?result.error.code==='23505'?'This WhatsApp contact is authorized for another guest. Review the guest identity first.':result.error.message:'Could not save. Refresh and try again.'};
 revalidatePath(`/p/${pid}/automations`);if(kind==='rule')redirect(`/p/${pid}/automations?tab=setup&notice=${fd.get('enabled')==='on'?'enabled':'saved'}&event=${encodeURIComponent(String(fd.get('event')??''))}`);return{success:'Guest permission saved. This does not grant marketing permission or override STOP.'};
}

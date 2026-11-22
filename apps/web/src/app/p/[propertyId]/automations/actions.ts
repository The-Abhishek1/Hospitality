'use server';
import{createClient}from'@/lib/supabase/server';import{revalidatePath}from'next/cache';
export type AutomationState={error?:string;success?:string};
export async function saveAutomation(_:AutomationState,fd:FormData):Promise<AutomationState>{
 const db=await createClient(),pid=String(fd.get('pid')??''),kind=String(fd.get('kind')??'');let result;
 if(kind==='rule'){
  let keys;try{keys=JSON.parse(String(fd.get('keys')??'[]'));}catch{return{error:'Invalid variable mapping.'};}
  result=await db.rpc('save_whatsapp_automation_rule',{p_property:pid,p_event:String(fd.get('event')),p_version:Number(fd.get('version')),p_enabled:fd.get('enabled')==='on',p_template:String(fd.get('template')??'')||null,p_keys:keys,p_delay:Number(fd.get('delay')??0)});
 }else if(kind==='permission'){
  result=await db.rpc('authorize_whatsapp_stay_updates',{p_property:pid,p_reservation:String(fd.get('reservation')),p_version:Number(fd.get('version')),p_status:String(fd.get('status')),p_evidence:String(fd.get('evidence')??''),p_confirmed:fd.get('confirmed')==='on'});
 }else return{error:'Unknown action.'};
 if(result.error)return{error:['22023','40001','42501','23505'].includes(result.error.code)?result.error.code==='23505'?'This WhatsApp contact is authorized for another guest. Review the guest identity first.':result.error.message:'Could not save. Refresh and try again.'};
 revalidatePath(`/p/${pid}/automations`);return{success:kind==='rule'?'Rule saved. Only new eligible events are processed; paused or changed rules suppress their old queue.':'Guest permission saved. This does not grant marketing permission or override STOP.'};
}

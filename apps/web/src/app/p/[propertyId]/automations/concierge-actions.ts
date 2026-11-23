'use server';
import{createClient}from'@/lib/supabase/server';import{revalidatePath}from'next/cache';
export type ConciergeState={error?:string;success?:string;version?:number;request?:string};
export async function saveConcierge(_:ConciergeState,fd:FormData):Promise<ConciergeState>{
 const pid=String(fd.get('pid')??'');let data;try{data=JSON.parse(String(fd.get('data')??''));}catch{return{error:'Check the menu form.'};}
 const db=await createClient(),version=Number(fd.get('version')),{error}=await db.rpc('save_whatsapp_guest_menu',{p_property:pid,p_version:version,p_enabled:fd.get('enabled')==='on',p_data:data});
 if(error)return{error:['22023','40001'].includes(error.code)?error.message:'Could not save this hotel’s guest menu. Check your administrator access and try again.'};
 revalidatePath(`/p/${pid}/automations`);revalidatePath(`/p/${pid}/inbox`);return{success:fd.get('enabled')==='on'?'Guest menu is live. Send Hi or MENU to this hotel’s WhatsApp number to test.':'Menu saved. Automatic replies are paused; staff can still share configured items from Inbox.',version:version+1};
}

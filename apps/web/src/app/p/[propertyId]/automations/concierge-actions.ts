'use server';
import{createClient}from'@/lib/supabase/server';import{revalidatePath}from'next/cache';import{defaultConcierge}from'@/lib/guest-concierge';
export type ConciergeState={error?:string;success?:string;version?:number;request?:string;savedEnabled?:boolean};
export async function saveConcierge(_:ConciergeState,fd:FormData):Promise<ConciergeState>{
 const pid=String(fd.get('pid')??'');let data;try{data=JSON.parse(String(fd.get('data')??''));if(!data||Array.isArray(data)||typeof data!=='object')throw Error();data={...data,intro:defaultConcierge.intro};}catch{return{error:'Check the menu form.'};}
 const db=await createClient(),version=Number(fd.get('version')),{error}=await db.rpc('save_whatsapp_guest_menu',{p_property:pid,p_version:version,p_enabled:fd.get('enabled')==='on',p_data:data});
 if(error)return{error:['22023','40001'].includes(error.code)?error.message:'Could not save this hotel’s guest menu. Check your administrator access and try again.'};
 revalidatePath(`/p/${pid}/automations`);revalidatePath(`/p/${pid}/inbox`);return{success:fd.get('enabled')==='on'?'Custom menu published. Guests receive its categories after Hi, Hello or MENU, following any required verification or preference checks.':'Custom menu saved without publishing. Publish it to use these categories and services in automatic replies.',version:version+1,savedEnabled:fd.get('enabled')==='on'};
}

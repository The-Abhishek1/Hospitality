'use server';
import {createClient} from '@/lib/supabase/server';
import {revalidatePath} from 'next/cache';
type State={error?:string;success?:string};
export async function saveJourney(_:State,fd:FormData):Promise<State>{
 const pid=String(fd.get('pid')??''),db=await createClient();
 const{error}=await db.rpc('save_whatsapp_journey',{p_property:pid,p_version:Number(fd.get('version')),p_enabled:fd.get('enabled')==='on',p_documents:Number(fd.get('documents')),p_self_checkin:fd.get('self_checkin')==='on',p_review_mode:String(fd.get('document_review_mode')??'photo')});
 if(error)return{error:['22023','40001','42501'].includes(error.code)?error.message:'Could not save the guest journey. Refresh and try again.'};
 revalidatePath(`/p/${pid}/automations`);return{success:'Guest journey saved. Configure and activate the approved event templates below before testing a new booking.'};
}

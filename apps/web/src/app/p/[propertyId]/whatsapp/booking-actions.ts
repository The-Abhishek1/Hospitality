'use server';
import {createClient} from '@/lib/supabase/server';
import {revalidatePath} from 'next/cache';
type State={error?:string;success?:string};
export async function saveWhatsAppBookings(_:State,fd:FormData):Promise<State>{
 const pid=String(fd.get('pid')??''),db=await createClient();
 const{error}=await db.rpc('save_whatsapp_booking_settings',{p_property:pid,p_version:Number(fd.get('version')),p_enabled:fd.get('enabled')==='on'});
 if(error)return{error:['22023','40001','42501'].includes(error.code)?error.message:'Could not save booking settings. Refresh and try again.'};
 revalidatePath(`/p/${pid}/whatsapp`);return{success:'WhatsApp booking preference saved.'};
}

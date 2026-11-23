'use server';
import {revalidatePath} from 'next/cache';
import {createClient} from '@/lib/supabase/server';
import {validId} from '@/lib/reservations';
export type GuestIdentityState={error?:string;success?:string};
export async function manageGuestIdentity(_:GuestIdentityState,fd:FormData):Promise<GuestIdentityState>{
 const text=(key:string)=>String(fd.get(key)??'').trim(),pid=text('pid'),guest=text('guest'),action=text('operation');
 if(!validId(pid)||!validId(guest)||!['reset','delete'].includes(action))return{error:'Refresh the guest list before continuing.'};
 const db=await createClient();const{error}=await db.rpc('manage_guest_identity',{p_property:pid,p_guest:guest,p_action:action,p_expected_phone:String(fd.get('phone')??''),p_confirm_name:text('confirmation'),p_reason:text('reason')});
 if(error)return{error:error.code==='42501'?'Hotel administrator access is required.':error.code==='40001'?'Guest details changed. Refresh and review the profile.':error.code==='22023'?error.message:'Couldn’t update this guest. Refresh and try again.'};
 revalidatePath(`/p/${pid}/reservations`,'layout');revalidatePath(`/p/${pid}/inbox`);revalidatePath(`/p/${pid}/automations`);revalidatePath('/dashboard');
 return{success:action==='delete'?'Unused guest profile deleted.':'WhatsApp link reset. History is preserved. Confirm the correct guest’s identity and collect fresh messaging permission before sending.'};
}

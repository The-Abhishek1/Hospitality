'use server';
import {createClient} from '@/lib/supabase/server';
import {revalidatePath} from 'next/cache';
import {validId} from '@/lib/reservations';
export async function saveStaff(pid:string,request:string,action:string,data:unknown){
 if(!validId(pid)||!validId(request)||JSON.stringify(data).length>250000)return {error:'Reload this form or use a smaller import.'};
 const db=await createClient(),{error}=await db.rpc('staff_manage',{p_property:pid,p_request:request,p_action:action,p_data:data});
 if(error)return {error:['22023','40001','42501','23505'].includes(error.code)?error.code==='23505'?'A staff code already exists. Check for duplicates.':error.message:'Could not save. Check the values and retry.'};
 revalidatePath(`/p/${pid}/staff`);return {success:true};
}

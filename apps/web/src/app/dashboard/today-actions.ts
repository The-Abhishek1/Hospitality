'use server';
import{revalidatePath}from'next/cache';
import{createClient}from'@/lib/supabase/server';
import{validId}from'@/lib/reservations';
export type TodayActionState={error?:string;success?:string};
export async function completeTodayStay(_:TodayActionState,fd:FormData):Promise<TodayActionState>{
 const pid=String(fd.get('property')??''),id=String(fd.get('reservation')??''),operation=String(fd.get('operation')??''),version=Number(fd.get('version'));
 if(!validId(pid)||!validId(id)||!['check_in','check_out'].includes(operation)||!Number.isInteger(version)||version<1||fd.get('confirmed')!=='on')return{error:'Refresh this stay and confirm the action before continuing.'};
 const db=await createClient(),{data:stay,error:readError}=await db.from('reservations').select('id').eq('property_id',pid).eq('id',id).maybeSingle();
 if(readError||!stay)return{error:'This stay is not available in this hotel.'};
 const{error}=await db.rpc('frontdesk_action',{p_id:id,p_version:version,p_action:operation,p_reason:''});
 if(error)return{error:error.code==='42501'?'Your role cannot complete this action.':error.code==='40001'?'This stay changed. Refresh Today before continuing.':['22023','P0002'].includes(error.code??'')?error.message:'Couldn’t update this stay. Refresh and try again.'};
 revalidatePath('/dashboard');revalidatePath(`/p/${pid}/reservations`,'layout');revalidatePath(`/p/${pid}/tasks`);revalidatePath(`/p/${pid}/billing`);
 return{success:operation==='check_in'?'Guest checked in.':'Guest checked out. Room marked for cleaning.'};
}

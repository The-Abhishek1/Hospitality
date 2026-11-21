'use server';
import {revalidatePath} from 'next/cache';
import {createClient} from '@/lib/supabase/server';
export type ReviewResult={error?:string;message?:string};
export async function reviewCommand(_:ReviewResult,fd:FormData):Promise<ReviewResult>{
 const value=(k:string)=>String(fd.get(k)||'');
 const pid=value('property'),caseId=value('case'),request=value('request');
 const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
 if(![pid,caseId,request].every(v=>uuid.test(v)))return{error:'Reload this review page and try again.'};
 const details:Record<string,unknown>={reason:value('reason').trim()};
 if(value('action')!=='retry')details.confirmed=fd.get('confirmed')==='on';
 if(value('action')==='link')details.reservation_id=value('reservation');
 const db=await createClient();
 const {data,error}=await db.rpc('channel_review_command',{p_property:pid,p_case:caseId,p_version:Number(fd.get('version')),p_request:request,p_action:value('action'),p_details:details});
 if(error)return{error:error.code==='40001'?'This case changed. Refresh the page before continuing.':error.code==='42501'?'Channel management access is required.':error.message};
 revalidatePath(`/p/${pid}/channels`);revalidatePath(`/p/${pid}/channels/review`);revalidatePath(`/p/${pid}/channels/review/${caseId}`);revalidatePath(`/p/${pid}/reservations`);
 return{message:data?.message||'Review action saved.'};
}

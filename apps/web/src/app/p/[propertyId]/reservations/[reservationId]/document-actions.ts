'use server';
import {createClient} from '@/lib/supabase/server';
import {processDocumentImage}from'@/lib/process-document-image';
import {revalidatePath} from 'next/cache';
type State={error?:string;success?:string;url?:string};
export async function reviewIdentity(_:State,fd:FormData):Promise<State>{
 const db=await createClient(),id=String(fd.get('document')??''),pid=String(fd.get('pid')??''),rid=String(fd.get('reservation')??''),decision=String(fd.get('decision')??'');
 const{data:doc,error:readError}=await db.from('guest_documents').select('id').eq('id',id).eq('property_id',pid).eq('reservation_id',rid).maybeSingle();
 if(readError||!doc)return{error:'Document unavailable for this stay.'};
 if(decision==='prepare'){
  const access=await db.rpc('document_photo_prepare_access',{p_document:id,p_reason:String(fd.get('note')??'')});if(access.error||access.data!==true)return{error:access.error?.message??'Document-review access required.'};
  try{const result=await processDocumentImage(id);revalidatePath(`/p/${pid}/reservations/${rid}`);return result.status==='image_ready'?{success:'Rebuilt photo ready. Open it securely and review the guest identity.'}:result.status==='image_invalid'?{error:result.message??'This photo needs replacing.'}:{success:'Photo preparation is pending. Refresh shortly.'};}catch{return{error:'Could not prepare this photo. Retry shortly.'};}
 }
 if(decision==='open'){
  const{data,error}=await db.functions.invoke('document-access',{body:{document_id:id,reason:String(fd.get('note')??'')}});
  if(error||!data?.url)return{error:'Only checked documents can be opened. Prepare the photo or wait for the configured scan, then try again.'};
  // Local Edge Functions sign against an internal Docker hostname. Use this app's
  // configured public API origin for the same private bucket and signed path.
  let signed:URL;
  try{signed=new URL(data.url);const api=new URL(process.env.NEXT_PUBLIC_SUPABASE_URL!);if(!signed.pathname.startsWith('/storage/v1/object/sign/guest-documents/')||signed.username||signed.password)throw Error();signed.protocol=api.protocol;signed.host=api.host;signed.hash='';}
  catch{return{error:'The private document link could not be verified. Contact the platform administrator.'};}
  return{url:signed.href,success:'Audited review link ready. It expires in 60 seconds.'};
 }
 if(!['approved','rejected'].includes(decision))return{error:'Choose approve or request a replacement.'};
 const{error}=await db.rpc('review_document',{p_doc:id,p_decision:decision,p_note:String(fd.get('note')??'')});
 if(error)return{error:['22023','42501'].includes(error.code)?error.message:'Could not save the review. Refresh before retrying.'};
 revalidatePath(`/p/${pid}/reservations/${rid}`);return{success:decision==='approved'?'Document approved. The configured WhatsApp notification runs when the required review is complete.':'Replacement requested. The configured WhatsApp notification will guide the guest.'};
}
export async function saveBookingContact(_:State,fd:FormData):Promise<State>{
 const db=await createClient(),pid=String(fd.get('pid')??''),rid=String(fd.get('reservation')??'');
 const{error}=await db.rpc('record_whatsapp_booking_contact',{p_property:pid,p_reservation:rid,p_evidence:String(fd.get('evidence')??''),p_confirmed:fd.get('confirmed')==='on'});
 if(error)return{error:['22023','42501'].includes(error.code)?error.message:'Could not record booking contact permission.'};
 revalidatePath(`/p/${pid}/reservations/${rid}`);return{success:'Booking contact permission recorded. An unexpired booking welcome can now run; ongoing updates still need the guest’s choice in WhatsApp.'};
}

export async function requestWelcome(_:State,fd:FormData):Promise<State>{const pid=String(fd.get('pid')??''),rid=String(fd.get('reservation')??''),db=await createClient();const{data,error}=await db.rpc('request_booking_welcome',{p_property:pid,p_reservation:rid});if(error)return{error:['22023','42501','P0002'].includes(error.code)?error.message:'Could not request this booking welcome.'};revalidatePath(`/p/${pid}/reservations/${rid}`);return{success:data.reason??'Booking welcome requested.'};}

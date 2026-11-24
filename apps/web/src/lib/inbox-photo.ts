import {createHash,randomUUID} from 'node:crypto';
import {createClient} from '@/lib/supabase/server';
import {backend} from '@/lib/whatsapp-onboarding';
import {rebuildDocumentPhoto} from '@/lib/document-image';
import {validId} from '@/lib/reservations';
export async function queueInboxPhoto(pid:string,fd:FormData){
 const cid=String(fd.get('cid')??''),request=String(fd.get('request')??''),caption=String(fd.get('body')??'').trim(),file=fd.get('photo');
 if(!validId(pid)||!validId(cid)||!validId(request)||caption.length>1024||!(file instanceof File)||file.size<12||file.size>4*1024*1024)throw Error('Choose a JPG or PNG up to 4 MB and a caption up to 1,024 characters.');
 const db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)throw Error('Sign in again before sending.');
 const{data:context,error}=await db.rpc('inbox_photo_context',{p_property:pid,p_conversation:cid,p_request:request});
 if(error)throw Error(['22023','42501'].includes(error.code)?error.message:'This conversation is unavailable.');
 const input=new Uint8Array(await file.arrayBuffer()),digest=createHash('sha256').update(input).digest('hex');
 let photo=context.photo;
 if(photo&&(photo.digest!==digest||photo.uploaded_by!==user.id))throw Error('This reply already has another photo. Refresh before sending a new message.');
 if(!photo){
  const rebuilt=await rebuildDocumentPhoto(input);if(rebuilt.data.length>4*1024*1024)throw Error('The rebuilt photo is too large. Choose a smaller image.');
  const admin=backend(),store=admin.storage.from('whatsapp-inbox-photos'),path=`${pid}/${cid}/${request}.jpg`;
  const upload=await store.upload(path,rebuilt.data,{contentType:'image/jpeg',upsert:false});
  // A concurrent or interrupted attempt must not replace a different file at this path.
  if(upload.error)throw Error('Photo could not be saved. Refresh the conversation and attach it again.');
  const signed=await store.createSignedUrl(path,7*24*60*60);
  if(signed.error||!signed.data){await store.remove([path]);throw Error('Photo delivery could not be prepared.');}
  const saved=await admin.from('inbox_photo_uploads').insert({id:randomUUID(),property_id:pid,conversation_id:cid,request_id:request,uploaded_by:user.id,storage_path:path,digest,delivery_url:signed.data.signedUrl,expires_at:new Date(Date.now()+7*24*60*60*1000).toISOString()}).select('id').single();
  if(saved.error){await store.remove([path]);throw Error('Photo could not be attached. Refresh and try again.');}photo=saved.data;
 }
 const queued=await db.rpc('inbox_send_photo',{p_property:pid,p_conversation:cid,p_request:request,p_photo:photo.id,p_caption:caption});
 if(queued.error)throw Error(['22023','40001','42501'].includes(queued.error.code)?queued.error.message:'Photo was saved but queuing could not be confirmed. Retry this same reply.');
 return queued.data as string;
}

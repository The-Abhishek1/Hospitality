import{createClient}from'@supabase/supabase-js';import{createHash}from'node:crypto';import{rebuildDocumentPhoto,InvalidDocumentPhoto}from'./document-image';
export async function processDocumentImage(document:string,token?:string){
 const db=createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.SUPABASE_SERVICE_ROLE_KEY!,{auth:{persistSession:false,autoRefreshToken:false}}),claim=await db.rpc('claim_document_image',{p_document:document,p_token:token??null});if(claim.error)throw Error('Photo preparation is unavailable for this document.');const job=claim.data;
 if(job.done)return{ok:true,status:job.status,review_method:'photo'};
 if(job.mode==='antivirus')return{ok:true,review_method:'antivirus'};
 if(job.processing)return{ok:true,review_method:'photo',processing:true};
 const store=db.storage.from('guest-documents');let uploaded=false;
 try{
  const file=await store.download(job.storage_path);if(file.error||!file.data||file.data.size!==job.size_bytes)throw Error('download');
  const photo=await rebuildDocumentPhoto(new Uint8Array(await file.data.arrayBuffer()));
  const result=await store.upload(job.preview_path,photo.data,{contentType:'image/jpeg',cacheControl:'0',upsert:false});if(result.error)throw Error('upload');uploaded=true;
  const complete=await db.rpc('complete_document_image',{p_document:document,p_lease:job.lease_id,p_result:'ready',p_size:photo.data.length,p_width:photo.width,p_height:photo.height,p_sha256:createHash('sha256').update(photo.data).digest('hex')});
  if(complete.error||complete.data!==true)throw Error('stale');return{ok:true,status:'image_ready',review_method:'photo'};
 }catch(error){
  if(uploaded)await store.remove([job.preview_path]);
  const invalid=error instanceof InvalidDocumentPhoto;await db.rpc('complete_document_image',{p_document:document,p_lease:job.lease_id,p_result:invalid?'invalid':'retry'});
  if(invalid)return{ok:true,status:'image_invalid',review_method:'photo',message:error.message};
  throw Error('Photo preparation could not finish. Your file remains private. Retry photo preparation.');
 }
}

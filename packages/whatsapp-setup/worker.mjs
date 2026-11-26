import{starterSlots,starterTemplate,legacyStarterBodies}from'./defaults.mjs';
export function templateSetupError(error,token=''){
 let detail=String(error?.error_data?.details||error?.error_user_msg||error?.message||'Template setup failed. Check the hotel connection and try again.');
 if(token)detail=detail.split(token).join('[redacted]');
 detail=detail.replace(/\bEA[A-Za-z0-9_-]{30,}\b/g,'[redacted]').replace(/access_token\s*[=:]\s*[^\s&]+/gi,'access_token=[redacted]').replace(/[\r\n\t<>]/g,' ').slice(0,280);
 const code=Number(error?.code),sub=Number(error?.error_subcode);
 return (code?`Meta ${code}${sub?` / ${sub}`:''}: `:'')+detail;
}
// Stable names reconcile uncertain creates. A bad slot must not block the rest of the pack.
export async function prepareHotelTemplates(job,io){
 const existing=await io.fetchTemplates();let created=0,attempted=0,handle;const errors=[];
 // Previously failed slots follow untouched slots, so repeated failures cannot starve setup.
 const slots=[...job.slots].sort((a,b)=>Number(Boolean(a.last_error))-Number(Boolean(b.last_error)));
 for(const saved of slots){
  const slot=starterSlots.find(s=>s.key===saved.slot);if(!slot)continue;
  // Reconcile a prior wording mismatch after a starter fix; explicit owner edits stay untouched.
  if(saved.state==='customized'&&saved.last_error!=='The provider template was customized. Keep it or create a replacement.')continue;
  const current=existing.find(t=>t.name===saved.name&&t.language==='en_US');
  const image=slot.key==='booking_confirmed'||slot.key==='menu_photos';
  if(!current&&attempted>=4)continue;
  if(!current)attempted++;
  let payload,result;
  try{
   if(image&&!handle&&!current)handle=await io.uploadImage(job.welcome_image_url);
   payload=starterTemplate(slot,{property_id:job.property_id,links:job.links,imageHandle:handle??'existing-sample'});
   if(!current){result=await io.create(payload);if(!result?.id)throw Error('Unconfirmed creation');}
  }catch(error){
   // Only provider-safe messages reach owners. Raw network/credential errors stay private.
   const reason=error?.safeMessage||'Template preparation could not be confirmed. Its existing name will be checked before retrying.';
   if(io.failed)await io.failed(saved.slot,reason);errors.push({slot:saved.slot,reason});continue;
  }
  if(current){
   const expected=payload.components.find(c=>c.type==='BODY').text;
   if(current.body!==expected&&current.body!==legacyStarterBodies[slot.key]){await io.record(saved.slot,current.provider_id,null,'The provider template was customized. Keep it or create a replacement.');continue;}
   await io.record(saved.slot,current.provider_id,image?job.welcome_image_url:null,null);continue;
  }
  // Persistence failures (including a revoked lease) abort before another provider mutation.
  await io.record(saved.slot,String(result.id),image?job.welcome_image_url:null,null);created++;
 }
 await io.sync(await io.fetchTemplates());return{created,errors};
}

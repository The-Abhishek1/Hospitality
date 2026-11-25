import{starterSlots,starterTemplate}from'./whatsapp-defaults.js';
// Provider mutations have stable names. A lost response is reconciled by lookup on the next run.
export async function prepareHotelTemplates(job,io){
 const existing=await io.fetchTemplates();let created=0,handle;
 for(const saved of job.slots){
  const slot=starterSlots.find(s=>s.key===saved.slot);if(!slot||saved.state==='customized')continue;
  const current=existing.find(t=>t.name===saved.name&&t.language==='en_US');
  const image=slot.key==='booking_confirmed'||slot.key==='menu_photos';
  if(!current&&created>=4)continue;
  if(image&&!handle&&!current)handle=await io.uploadImage(job.welcome_image_url);
  const payload=starterTemplate(slot,{property_id:job.property_id,links:job.links,imageHandle:handle??'existing-sample'});
  if(current){
   const expected=payload.components.find(c=>c.type==='BODY').text;
   if(current.body!==expected){await io.record(saved.slot,current.provider_id,null,'The provider template was customized. Keep it or create a replacement.');continue;}
   await io.record(saved.slot,current.provider_id,image?job.welcome_image_url:null,null);continue;
  }
  // Repeated setup never creates a second differently named copy after an uncertain outcome.
  const result=await io.create(payload);if(!result?.id)throw Error('Meta did not confirm template creation. The next run will check its stable name.');
  await io.record(saved.slot,String(result.id),image?job.welcome_image_url:null,null);created++;
 }
 await io.sync(await io.fetchTemplates());return{created};
}

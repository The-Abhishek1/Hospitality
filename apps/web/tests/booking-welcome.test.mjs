import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
const compile=s=>ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const moduleUrl=s=>`data:text/javascript;base64,${Buffer.from(compile(s)).toString('base64')}`;
const flow=moduleUrl(readFileSync(new URL('../src/lib/automation-flow.ts',import.meta.url),'utf8'));
const source=readFileSync(new URL('../src/lib/booking-welcome.ts',import.meta.url),'utf8').replace("'./automation-flow'",JSON.stringify(flow));
const {welcomeKeys,welcomeDraft}=await import(moduleUrl(source));
const template={body:'Hello {{guest_name}}, upload securely at {{portal_url}}. Contact reception for help.',language:'en_US',parameters:['guest_name','portal_url'],supported:true,status:'APPROVED',category:'utility',checked_at:new Date().toISOString()};
test('welcome needs approved operational content and a per-booking document link',()=>{
 assert.deepEqual(welcomeKeys(template),['guest_name','portal_url']);
 for(const patch of [{status:'PENDING'},{category:'marketing'},{parameters:['guest_name']},{parameters:['order_reference','portal_url']},{checked_at:'2000-01-01T00:00:00Z'}])assert.equal(welcomeKeys({...template,...patch}),null);
});
test('legacy numbered welcome fields preserve explicit mappings without guessing guest data',()=>{
 const numbered={...template,parameters:['1','2']};assert.equal(welcomeKeys(numbered),null);
 assert.deepEqual(welcomeKeys(numbered,['guest_name','portal_url']),['guest_name','portal_url']);
 assert.equal(welcomeKeys(numbered,['guest_name','order_reference']),null);
});
test('editing a welcome keeps its language, photo, footer and public link buttons',()=>{
 const draft=welcomeDraft({...template,image_url:'https://hotel.test/welcome.jpg',definition:{components:[{type:'HEADER',format:'IMAGE'},{type:'FOOTER',text:'See you soon'},{type:'BUTTONS',buttons:[{type:'URL',text:'Location',url:'https://maps.google.com/hotel'}]}]}});
 assert.equal(draft.body,template.body);assert.equal(draft.extras.image_url,'https://hotel.test/welcome.jpg');assert.equal(draft.extras.header_kind,'image');assert.equal(draft.extras.footer,'See you soon');assert.deepEqual(draft.extras.buttons,[{text:'Location',url:'https://maps.google.com/hotel'}]);
 assert.match(welcomeDraft().body,/\{\{portal_url\}\}/);assert.doesNotMatch(welcomeDraft({...template,body:'Hello {{1}}, welcome.'}).body,/\{\{1\}\}/);
});
const {send}=await import(moduleUrl(readFileSync(new URL('../../../services/notification-worker/src/transport.ts',import.meta.url),'utf8')));
test('photo and caption use the existing provider transport without falling back to text',async()=>{
 let posted;const id=await send({phone_number_id:'123',credentials_ref:'synthetic',wa_contact_id:'919000000000',msg_type:'image',msg_body:'Hotel photo',template_name:null,template_language:null,outbound_payload:{type:'image',image:{link:'https://hotel.test/photo.jpg',caption:'Hotel photo'}}},'synthetic-token','https://provider.test',async(_url,init)=>{posted=JSON.parse(init.body);return new Response(JSON.stringify({messages:[{id:'synthetic-photo'}]}),{status:200});});
 assert.equal(id,'synthetic-photo');assert.deepEqual(posted,{messaging_product:'whatsapp',to:'919000000000',type:'image',image:{link:'https://hotel.test/photo.jpg',caption:'Hotel photo'}});
});

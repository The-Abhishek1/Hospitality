import {test} from 'node:test';
import assert from 'node:assert/strict';
import {send,DeliveryError} from '../dist/transport.js';
const job={phone_number_id:'12345',credentials_ref:'test-ref',wa_contact_id:'910000',msg_type:'text',msg_body:'Hello',template_name:null,template_language:null};
test('successful transport validates the provider ID and sets a request deadline',async()=>{
 const id=await send(job,'test-token','https://provider.invalid',async(url,opts)=>{assert.equal(url,'https://provider.invalid/12345/messages');assert.ok(opts.signal instanceof AbortSignal);assert.equal(JSON.parse(opts.body).text.body,'Hello');return new Response(JSON.stringify({messages:[{id:'wamid-test'}]}));});assert.equal(id,'wamid-test');
});
test('missing server credentials never make a provider request',async()=>{
 let called=false;await assert.rejects(()=>send(job,undefined,'https://provider.invalid',async()=>{called=true;return new Response();}),e=>e instanceof DeliveryError&&!e.retryable&&!e.uncertain);assert.equal(called,false);
});
test('provider throttling and transient errors can be retried',async()=>{
 for(const status of [429,500,503])await assert.rejects(()=>send(job,'test','https://provider.invalid',async()=>new Response(JSON.stringify({error:{message:'Temporary'}}),{status})),e=>e instanceof DeliveryError&&e.retryable&&!e.uncertain);
});
test('permanent provider rejection is terminal',async()=>{
 await assert.rejects(()=>send(job,'test','https://provider.invalid',async()=>new Response('{}',{status:400})),e=>e instanceof DeliveryError&&!e.retryable&&!e.uncertain);
});
test('network failures and accepted responses with no message ID require reconciliation',async()=>{
 await assert.rejects(()=>send(job,'test','https://provider.invalid',async()=>{throw new Error('network');}),e=>e instanceof DeliveryError&&e.uncertain&&!e.retryable);
 await assert.rejects(()=>send(job,'test','https://provider.invalid',async()=>new Response('{}')),e=>e instanceof DeliveryError&&e.uncertain&&!e.retryable);
});
test('template transport uses the approved name and language',async()=>{
 await send({...job,msg_type:'template',template_name:'welcome',template_language:'en'},'test','https://provider.invalid',async(_url,opts)=>{const p=JSON.parse(opts.body);assert.equal(p.type,'template');assert.deepEqual(p.template,{name:'welcome',language:{code:'en'}});return new Response(JSON.stringify({messages:[{id:'template-test'}]}));});
});
test('automation transport preserves approved named and positional parameters',async()=>{
 const components=[{type:'body',parameters:[{type:'text',parameter_name:'guest_name',text:'Asha'},{type:'text',parameter_name:'portal_url',text:'https://guest.invalid/s/test'}]}];
 await send({...job,msg_type:'template',template_name:'stay_update',template_language:'en_US',template_components:components},'test','https://provider.invalid',async(_url,opts)=>{
  const p=JSON.parse(opts.body);assert.deepEqual(p.template.components,components);assert.equal(p.template.language.code,'en_US');return new Response(JSON.stringify({messages:[{id:'automation-test'}]}));
 });
});

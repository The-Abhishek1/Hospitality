import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
import {normalizeTemplate} from '../../../packages/whatsapp-security/templates.mjs';
const code=ts.transpileModule(readFileSync(new URL('../src/lib/automation-flow.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {isMetaSampleTemplate,automationStarters,eventFields,createTemplatePayload,templateUsable,setupNext,previewAutomation,templateProviderError}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const input={event:'checked_in',name:'hotel_checked_in',language:'en_US',body:automationStarters.checked_in};
test('all 30 event starters produce provider templates compatible with actual delivery transport',()=>{
 assert.equal(Object.keys(automationStarters).length,30);
 for(const[event,body]of Object.entries(automationStarters)){
  const payload=createTemplatePayload({...input,event,body});
  const normalized=normalizeTemplate({...payload,id:'test',status:'PENDING'});
  assert.equal(normalized.supported,true,event);
  assert.equal(normalized.category,event==='review_request'?'marketing':'utility');
  assert.equal(normalized.provider_status,'PENDING');
  assert.equal(payload.components[0].example.body_text_named_params.length,normalized.parameter_names.length);
  assert.doesNotMatch(previewAutomation(body),/\{\{|\[Choose/);
 }
});
test('reject malformed names, unsupported events/languages, overlong or invalid placeholders',()=>{
 for(const patch of [{name:'Guest Welcome'},{event:'made_up'},{language:'made_up'},{body:'x'.repeat(1025)},{body:'Hello {{1}}, welcome to {{hotel_name}}.'},{body:'Hello {{secret_key}}, welcome here.'},{body:'Hello {{guest_name, welcome here.'}])assert.throws(()=>createTemplatePayload({...input,...patch}));
});
test('reject event-specific fields when the event cannot provide them',()=>{
 for(const key of ['order_reference','request_title','invoice_number','review_url']){assert.ok(!eventFields('checked_in').includes(key));assert.throws(()=>createTemplatePayload({...input,body:`Hello {{guest_name}}, your update: {{${key}}}.`}));}
 assert.throws(()=>createTemplatePayload({...input,event:'booking_cancelled',body:'Hello {{guest_name}}, view your stay: {{portal_url}}. Contact reception.'}));
});
test('static templates need no examples; repeated named fields need only one example',()=>{
 assert.equal(createTemplatePayload({...input,body:'Your check-in has been confirmed. Welcome to our hotel.'}).parameter_format,undefined);
 const p=createTemplatePayload({...input,body:'Hello {{guest_name}}, welcome {{guest_name}}. Enjoy your stay.'});
 assert.equal(p.components[0].example.body_text_named_params.length,1);
});
test('template eligibility gates pending, unsupported, wrong category and stale approval',()=>{
 const now=Date.parse('2026-11-22T12:00:00Z'),template={supported:true,status:'APPROVED',category:'utility',checked_at:new Date(now).toISOString()};
 assert.equal(templateUsable(template,'checked_in',now),true);
 for(const patch of [{supported:false},{status:'PENDING'},{category:'marketing'},{checked_at:'invalid'},{checked_at:new Date(now-86400001).toISOString()}])assert.equal(templateUsable({...template,...patch},'checked_in',now),false);
 assert.equal(templateUsable({...template,category:'marketing'},'review_request',now),true);
});
test('numbered parameters are never silently guessed in the preview',()=>{
 assert.equal(previewAutomation('Hello {{1}}',[],['1']),'Hello [Choose 1]');
 assert.equal(previewAutomation('Hello {{1}}',['guest_name'],['1']),'Hello Alex');
});
test('existing templates expose only fields available for the selected event',()=>{
 const now=Date.now(),template={supported:true,status:'APPROVED',category:'utility',checked_at:new Date(now).toISOString()};
 for(const field of ['order_reference','request_title','invoice_number','review_url'])assert.equal(templateUsable({...template,parameters:[field]},'checked_in',now),false,field);
 assert.equal(templateUsable({...template,parameters:['portal_url']},'booking_cancelled',now),false);
 assert.equal(templateUsable({...template,parameters:['order_reference']},'order_ready',now),true);
 assert.equal(templateUsable({...template,parameters:['1','customer']},'checked_in',now),true,'numbered and custom names can be explicitly mapped');
 for(const event of ['service_reply','unknown'])assert.equal(templateUsable(template,event,now),false,'only catalog events can be activation targets');
 for(const[event,body]of Object.entries(automationStarters))assert.equal(templateUsable({...template,category:event==='review_request'?'marketing':'utility',parameters:[...body.matchAll(/\{\{(\w+)\}\}/g)].map(m=>m[1])},event,now),true,event);
});
test('setup recommends the first incomplete step in order',()=>{
 const state={connected:false,approved:0,rules:0,permissions:0,worker:false};
 assert.equal(setupNext(state),'connection');state.connected=true;
 assert.equal(setupNext(state),'templates');state.approved=1;
 assert.equal(setupNext(state),'rules');state.rules=1;
 assert.equal(setupNext(state),'permissions');state.permissions=1;
 assert.equal(setupNext(state),'worker');state.worker=true;
 assert.equal(setupNext(state),'test');
});

test('Meta rejects boundary parameters even when separated from the edge by punctuation',()=>{
 for(const body of ['{{guest_name}}, welcome to our hotel.','... {{guest_name}}, welcome to our hotel.','Hello, view your stay: {{portal_url}}.','Hello {{guest_name}}!','Hello {{guest_name}}... \n'])assert.throws(()=>createTemplatePayload({...input,body}),/written text/);
 assert.doesNotThrow(()=>createTemplatePayload({...input,body:'Hello {{guest_name}}. Enjoy your stay!'}));
});
test('template errors preserve provider reason and redact credentials without unrelated reconnect advice',()=>{
 const error=templateProviderError({code:100,error_subcode:2388299,error_user_title:'Leading or trailing params not allowed',error_user_msg:"Variables can't be at the start or end of the template. private-test-token"},400,'private-test-token');
 assert.match(error,/2388299/);assert.match(error,/Variables can't/);assert.doesNotMatch(error,/private-test-token|Reconnect/);
 assert.match(templateProviderError({code:190,message:'Expired token'},400,''),/Reconnect/);
});

test('only known Meta samples are separated from hotel templates',()=>{for(const name of ['hello_world','jaspers_market_image_cta_v1','jaspers_market_media_carousel_v1','jaspers_market_order_confirmation_v1','jaspers_market_plain_text_v1'])assert.equal(isMetaSampleTemplate(name),true);for(const name of ['hotel_checkin','hotel_review','jaspers_market_airport_pickup','hello_world_hotel'])assert.equal(isMetaSampleTemplate(name),false);});

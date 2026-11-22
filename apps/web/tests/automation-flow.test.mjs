import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
import {normalizeTemplate} from '../../../packages/whatsapp-security/templates.mjs';
const code=ts.transpileModule(readFileSync(new URL('../src/lib/automation-flow.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {automationStarters,eventFields,createTemplatePayload,templateUsable,setupNext,previewAutomation}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const input={event:'checked_in',name:'hotel_checked_in',language:'en_US',body:automationStarters.checked_in};
test('all 23 event starters produce provider templates compatible with actual delivery transport',()=>{
 assert.equal(Object.keys(automationStarters).length,23);
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
 assert.throws(()=>createTemplatePayload({...input,event:'booking_cancelled',body:automationStarters.checked_in}));
});
test('static templates need no examples; repeated named fields need only one example',()=>{
 assert.equal(createTemplatePayload({...input,body:'Your check-in has been confirmed. Welcome to our hotel.'}).parameter_format,undefined);
 const p=createTemplatePayload({...input,body:'Hello {{guest_name}}, welcome {{guest_name}}.'});
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
test('setup recommends the first incomplete step in order',()=>{
 const state={connected:false,approved:0,rules:0,permissions:0,worker:false};
 assert.equal(setupNext(state),'connection');state.connected=true;
 assert.equal(setupNext(state),'templates');state.approved=1;
 assert.equal(setupNext(state),'rules');state.rules=1;
 assert.equal(setupNext(state),'permissions');state.permissions=1;
 assert.equal(setupNext(state),'worker');state.worker=true;
 assert.equal(setupNext(state),'test');
});

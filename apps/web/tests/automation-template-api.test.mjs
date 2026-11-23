import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';
const compile=file=>ts.transpileModule(readFileSync(new URL(file,import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const flow={};vm.runInNewContext(compile('../src/lib/automation-flow.ts'),{exports:flow});
const rich={};vm.runInNewContext(compile('../src/lib/rich-templates.ts'),{exports:rich,require:()=>flow,URL});
const routeCode=compile('../src/app/api/whatsapp/[propertyId]/templates/route.ts');
const origin='https://hotel.example',pid='test-property',payload={action:'submit',event:'checked_in',name:'hotel_checked_in',language:'en_US',body:flow.automationStarters.checked_in};
function harness(options={}){
 const calls=[],out={},rows=[{name:payload.name,language:payload.language,category:'utility',provider_status:options.status??'PENDING',supported:true}];
 class SetupError extends Error{}
 const deps={
  'next/server':{NextResponse:{json:(body,init)=>new Response(JSON.stringify(body),init)}},
  '@/lib/supabase/server':{createClient:async()=>({auth:{getUser:async()=>({data:{user:options.anonymous?null:{id:'owner'}}})},rpc:async()=>({data:{connection:{status:'active',id:'connection',waba_id:'hotel-waba'}},error:options.forbidden?{message:'Forbidden'}:null})})},
  '@/lib/whatsapp-onboarding':{SetupError,graphVersion:'v27.0',savedToken:async()=>{calls.push('credential');return'private-token';},meta:async(path,token,method='GET',body,context)=>{calls.push({path,method,body,context});if(options.providerError&&method==='POST')throw new SetupError(options.providerError);return{data:options.duplicate?[{name:payload.name,language:payload.language}]:[],id:'provider-id'};},backend:()=>({rpc:async()=>{calls.push('sync-db');return{error:options.syncFailure?{}:null};},from:()=>({upsert:async()=>({error:null}),select:()=>({eq:()=>({eq:()=>({eq:()=>({maybeSingle:async()=>({data:{id:'local-template-id'}})})})})})})})},
  '@/lib/automation-flow':flow,'@/lib/rich-templates':rich,'@/lib/template-media':{uploadTemplateSample:async()=>"sample-handle"},
  '../../../../../../../../packages/whatsapp-security/templates.mjs':{fetchTemplates:async()=>{calls.push('fetch-directory');return rows;}}
 };
 vm.runInNewContext(routeCode,{exports:out,require:name=>{assert.ok(deps[name],`Unexpected dependency: ${name}`);return deps[name];},process:{env:{WHATSAPP_ONBOARDING_ORIGIN:origin}},URLSearchParams,console});
 return{calls,async invoke(body,requestOrigin=origin){const req=new Request(`${origin}/api/whatsapp/${pid}/templates`,{method:'POST',headers:{origin:requestOrigin},...(body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)})});req.nextUrl=new URL(req.url);const response=await out.POST(req,{params:Promise.resolve({propertyId:pid})});return{status:response.status,body:await response.json()};}};
}
test('cross-origin, anonymous and unauthorized users cannot access credentials or Meta',async()=>{
 for(const[options,requestOrigin,status]of [[{},'https://other.example',403],[{anonymous:true},origin,401],[{forbidden:true},origin,403]]){const h=harness(options);assert.equal((await h.invoke(payload,requestOrigin)).status,status);assert.equal(h.calls.length,0);}
});
test('invalid template payload is rejected before reading a credential',async()=>{
 for(const value of ['bad json',{action:'submit',event:'checked_in'},{...payload,body:'Hello {{secret}}, invalid template.'},{...payload,body:'Hello {{guest_name}}, view your stay: {{portal_url}}.'},{action:'delete'}]){const h=harness();assert.equal((await h.invoke(value)).status,400);assert.equal(h.calls.length,0);}
});
test('sync refreshes the provider directory without creating a template',async()=>{
 const h=harness();assert.equal((await h.invoke()).status,200);assert.ok(h.calls.includes('fetch-directory'));assert.ok(h.calls.includes('sync-db'));assert.equal(h.calls.filter(c=>c.method==='POST').length,0);
});
test('explicit reviewed submission uses the connected WABA and waits for approval',async()=>{
 const h=harness(),result=await h.invoke(payload),posts=h.calls.filter(c=>c.method==='POST');assert.equal(result.status,200);assert.equal(result.body.submitted,true);assert.equal(result.body.status,'PENDING');assert.equal(result.body.ready,false);assert.equal(posts.length,1);assert.equal(posts[0].path,'hotel-waba/message_templates');assert.equal(posts[0].context,'template');assert.equal(posts[0].body.parameter_format,'NAMED');assert.equal(JSON.parse(posts[0].body.components)[0].type,'BODY');
});
test('existing provider name/language prevents duplicate submission',async()=>{
 const h=harness({duplicate:true});assert.equal((await h.invoke(payload)).status,409);assert.equal(h.calls.filter(c=>c.method==='POST').length,0);
});
test('accepted submission with failed sync is not reported as needing a new submission',async()=>{
 const h=harness({syncFailure:true}),result=await h.invoke(payload);assert.equal(result.status,200);assert.equal(result.body.submitted,true);assert.match(result.body.success,/accepted/);assert.equal(h.calls.filter(c=>c.method==='POST').length,1);
});

test('provider submission failures preserve the specific actionable template rejection',async()=>{
 const message="Meta rejected the template request (code 100/2388299): Variables can't be at the start or end of the template.",h=harness({providerError:message}),result=await h.invoke(payload);
 assert.equal(result.status,400);assert.equal(result.body.error,message);assert.ok(!h.calls.includes('sync-db'));
});

test('explicit image template submission supplies the Meta upload handle and saves the template',async()=>{
 const h=harness(),result=await h.invoke({...payload,event:'service_reply',header_kind:'image',image_url:'https://hotel.example/sample.jpg',footer:'Hotel team',buttons:[{text:'Location',url:'https://maps.google.com/hotel'}]});
 assert.equal(result.status,200);assert.equal(result.body.submitted,true);const post=h.calls.find(c=>c.method==='POST');const parts=JSON.parse(post.body.components);assert.equal(parts[0].example.header_handle[0],'sample-handle');assert.equal(parts.at(-1).buttons[0].url,'https://maps.google.com/hotel');
});

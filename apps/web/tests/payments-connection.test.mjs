import{test}from'node:test';import assert from'node:assert/strict';import{readFileSync}from'node:fs';import vm from'node:vm';import ts from'typescript';
const pid='e3000000-0000-0000-0000-000000000001',origin='https://hotel.test';
const code=ts.transpileModule(readFileSync(new URL('../src/app/api/payments/[propertyId]/connection/route.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
function harness(options={}){const calls=[],exports={},deps={
 'next/server':{NextResponse:{json:(body,init)=>new Response(JSON.stringify(body),init)}},
 'node:crypto':{randomUUID:()=>pid,randomBytes:()=>({toString:()=> 'synthetic-webhook-secret'})},
 '@/lib/supabase/server':{createClient:async()=>({auth:{getUser:async()=>({data:{user:options.anonymous?null:{id:'owner'}}})},rpc:async()=>({data:{can_configure:!options.forbidden}})})},
 '@/lib/reservations':{validId:s=>s===pid},
 '@/lib/whatsapp-onboarding':{backend:()=>({rpc:async(name,args)=>{calls.push({name,args});return{data:pid};}})},
 '../../../../../../../../packages/whatsapp-security/index.mjs':{encryptToken:()=> 'encrypted-synthetic-credentials'},
 '../../../../../../../../packages/razorpay/index.mjs':{validKeys:(id,secret)=>/^rzp_(test|live)_/.test(id)&&secret.length>=10,client:()=>({verify:async()=>{calls.push({verify:true});}})}
 };vm.runInNewContext(code,{exports,require:name=>{assert.ok(deps[name],name);return deps[name];},process:{env:{APP_URL:origin,PAYMENTS_ENCRYPTION_KEY:'a'.repeat(64)}}});
 return{calls,async invoke(body={},requestOrigin=origin){const req=new Request(origin+'/api/payments/'+pid+'/connection',{method:'POST',headers:{origin:requestOrigin},body:JSON.stringify({action:'connect',keySecret:'synthetic-key-secret',...body})});req.nextUrl=new URL(req.url);return exports.POST(req,{params:Promise.resolve({propertyId:pid})});}};
}
test('payment account setup requires the owning administrator and configured origin',async()=>{for(const[options,status]of[[{anonymous:true},401],[{forbidden:true},403]]){const h=harness(options);assert.equal((await h.invoke()).status,status);assert.equal(h.calls.length,0);}const h=harness();assert.equal((await h.invoke({},'https://other.test')).status,403);assert.equal(h.calls.length,0);});
test('a mode mismatch, unconfirmed Live Mode or ordinary test hotel cannot reach Razorpay',async()=>{for(const body of[{mode:'test',keyId:'rzp_live_synthetic',testHotel:true},{mode:'live',keyId:'rzp_live_synthetic'},{mode:'test',keyId:'rzp_test_synthetic',testHotel:false}]){const h=harness();assert.equal((await h.invoke(body)).status,400);assert.equal(h.calls.length,0);}});
test('verified test and explicitly confirmed live credentials are saved encrypted per hotel',async()=>{for(const mode of['test','live']){const h=harness(),r=await h.invoke({mode,keyId:`rzp_${mode}_synthetic`,testHotel:mode==='test',liveConfirmed:mode==='live'});assert.equal(r.status,200);assert.equal(h.calls[0].verify,true);const saved=h.calls[1];assert.equal(saved.name,'payment_connection_commit');assert.equal(saved.args.p_property,pid);assert.ok(saved.args.p_key_hint.startsWith(`rzp_${mode}_`));assert.equal(saved.args.p_test_hotel,mode==='test');assert.equal(saved.args.p_ciphertext,'encrypted-synthetic-credentials');assert.ok(!(await r.text()).includes('synthetic-key-secret'));}});

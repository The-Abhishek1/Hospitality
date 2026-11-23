import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';

const source=readFileSync(new URL('../../../supabase/functions/whatsapp-worker/index.ts',import.meta.url),'utf8');
const compiled=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext}}).outputText.replace(/^import .*;\s*$/gm,'');
function worker(settings={},failCampaign=false){
 const calls=[];let handler;
 const chain={select(){return this;},eq(){return this;},lte(){return this;},order(){return this;},limit:async()=>({data:[]})};
 const db={from:()=>chain,rpc:async(name,args)=>{calls.push({name,args});return name==='dispatch_whatsapp_campaigns'&&failCampaign?{error:{message:'dispatch failed'}}:{data:name==='claim_outbound_messages_v5'?[]:0,error:null};}};
 const env={WHATSAPP_WORKER_SECRET:'test-worker-secret',...settings};
 new Function('Deno','createClient','decryptToken','fetchTemplates','send','DeliveryError','console',compiled)(
  {env:{get:key=>env[key]},serve:value=>{handler=value;}},()=>db,()=>{throw Error('No credential read expected');},()=>[],()=>{throw Error('No transport expected');},class extends Error {},{error(){}});
 return{calls,invoke:async(secret='test-worker-secret')=>handler(new Request('https://worker.test',{method:'POST',headers:{'x-worker-secret':secret}}))};
}
test('hosted campaigns remain disabled unless explicitly enabled',async()=>{
 for(const value of [undefined,'false','1']){const w=worker({WHATSAPP_CAMPAIGNS_ENABLED:value});assert.equal((await w.invoke()).status,200);assert.ok(!w.calls.some(c=>c.name==='dispatch_whatsapp_campaigns'));assert.equal(w.calls.find(c=>c.name==='claim_outbound_messages_v5').args.p_allow_campaigns,false);}
});
test('enabled hosted worker expands due campaigns before claiming with campaign capability',async()=>{
 const w=worker({WHATSAPP_CAMPAIGNS_ENABLED:'true',WHATSAPP_AUTOMATIONS_ENABLED:'true'});assert.equal((await w.invoke()).status,200);
 const dispatch=w.calls.findIndex(c=>c.name==='dispatch_whatsapp_campaigns'),claim=w.calls.findIndex(c=>c.name==='claim_outbound_messages_v5');assert.ok(dispatch>=0&&claim>dispatch);
 assert.deepEqual(w.calls[claim].args,{p_limit:1,p_allow_campaigns:true,p_allow_automations:true});assert.ok(w.calls.some(c=>c.name==='dispatch_whatsapp_automations'));
});
test('campaign dispatch failure records unhealthy completion and does not claim messages',async()=>{
 const w=worker({WHATSAPP_CAMPAIGNS_ENABLED:'true'},true);assert.equal((await w.invoke()).status,500);assert.ok(!w.calls.some(c=>c.name==='claim_outbound_messages_v5'));assert.equal(w.calls.at(-1).args.p_ok,false);
});
test('an unauthorized caller cannot activate or drain campaigns',async()=>{
 const w=worker({WHATSAPP_CAMPAIGNS_ENABLED:'true'});assert.equal((await w.invoke('wrong-secret')).status,403);assert.equal(w.calls.length,0);
});

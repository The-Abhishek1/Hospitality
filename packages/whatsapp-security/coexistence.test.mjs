import{test}from'node:test';import assert from'node:assert/strict';
import{coexistenceBatch,requestCoexistenceSync}from'./coexistence.mjs';import{signupEvent,signupFailure}from'./signup-event.mjs';
const stamp='1739230955',sample={id:'wamid.1',type:'text',timestamp:stamp,text:{body:'Hi'}};
test('Trusted Meta errors stop waiting without exposing raw provider data',()=>{const event={type:'WA_EMBEDDED_SIGNUP',event:'ERROR',data:{error_code:3441107,error_message:'private raw diagnostic'}};assert.match(signupFailure('https://www.facebook.com',event),/Advanced Access/);assert.doesNotMatch(signupFailure('https://www.facebook.com',event),/private raw diagnostic/);assert.equal(signupFailure('https://attacker.test',event),null);});
test('Coexistence finish accepts WABA-only and complete events only from exact Meta origins',()=>{
 const event={type:'WA_EMBEDDED_SIGNUP',event:'FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING',data:{waba_id:'1234567'}};
 assert.deepEqual(signupEvent('https://www.facebook.com',event),{waba:'1234567',coexistence:true});
 assert.deepEqual(signupEvent('https://business.facebook.com',{...event,data:{...event.data,phone_number_id:'7654321'}}),{waba:'1234567',phone:'7654321',coexistence:true});
 for(const origin of['https://facebook.com.attacker.test','https://evil.test','null'])assert.equal(signupEvent(origin,event),null);
 assert.equal(signupEvent('https://www.facebook.com',{...event,data:{phone_number_id:'7654321'}}),null);
 assert.equal(signupEvent('https://www.facebook.com',{...event,data:{waba_id:'invalid'}}),null);
});
test('History separates business and guest direction, preserving timestamps and status',()=>{
 const d=coexistenceBatch('history',{metadata:{display_phone_number:'+91 90000 00001'},history:[{metadata:{progress:100},threads:[{id:'15550000001',messages:[{...sample,from:'919000000001',history_context:{status:'read'}},{...sample,id:'wamid.2',from:'15550000001'}]}]}]});
 assert.deepEqual(d.records.map(m=>[m.source,m.direction,m.status]),[['history','out','read'],['history','in','sent']]);assert.equal(d.summary.progress,100);assert.equal(d.records[1].body,'Hi');assert.equal(d.records[0].sent_at,'2025-02-10T23:42:35.000Z');
});
test('Phone app echoes are outgoing, never guest commands',()=>{
 const d=coexistenceBatch('smb_message_echoes',{message_echoes:[{...sample,from:'919000000001',to:'15550000001'}]});assert.equal(d.records[0].direction,'out');assert.equal(d.records[0].source,'business_app');assert.equal(d.records[0].phone,'15550000001');
});
test('Contact import keeps add/remove and BSUID separate from phone identities',()=>{
 const d=coexistenceBatch('smb_app_state_sync',{state_sync:[{type:'contact',contact:{full_name:'Alex',phone_number:'+1 5550000001'},action:'add',metadata:{timestamp:stamp}},{type:'contact',contact:{user_id:'user-123',first_name:'Sam'},action:'remove',metadata:{timestamp:stamp}}]});
 assert.equal(d.records[0].contact_key,'phone:15550000001');assert.equal(d.records[1].phone,null);assert.equal(d.records[1].removed,true);assert.equal(d.records[1].contact_key,'user:user-123');
});
test('Phone-less messages stay unmatched rather than guessing another guest',()=>{
 const d=coexistenceBatch('history',{history:[{threads:[{context:{user_id:'user-123'},messages:[{...sample,from_user_id:'user-123'}]}]}]});assert.equal(d.records.length,1);assert.equal(d.records[0].phone,null);
});
test('Large histories use stable bounded batches and retain media placeholders',()=>{
 const payload={metadata:{display_phone_number:'919000000001'},history:[{threads:[{id:'15550000001',messages:Array.from({length:401},(_,i)=>({...sample,id:'wamid.'+i,from:'15550000001',type:i===400?'media_placeholder':'text'}))}]}]};
 const first=coexistenceBatch('history',payload),second=coexistenceBatch('history',payload,first.next),last=coexistenceBatch('history',payload,second.next);
 assert.equal(first.records.length,200);assert.equal(second.records.length,200);assert.equal(last.records.length,1);assert.equal(last.records[0].type,'media_placeholder');assert.equal(last.done,true);assert.throws(()=>coexistenceBatch('history',payload,402));
});
test('History declined is an explicit result and invalid timestamps are skipped',()=>{
 const d=coexistenceBatch('history',{history:[{errors:[{code:2593109}],threads:[{id:'15550000001',messages:[{...sample,timestamp:'not-a-date'}]}]}]});assert.equal(d.summary.declined,true);assert.equal(d.records.length,0);
});
test('One-time sync requests use only the expected endpoint and types',async()=>{
 const calls=[];const result=await requestCoexistenceSync({phone:'1234567',kind:'history',token:'private'},async(url,options)=>{calls.push({url,options});return Response.json({request_id:'request-1'});});assert.deepEqual(result,{state:'requested',request:'request-1'});assert.equal(calls.length,1);assert.equal(calls[0].url,'https://graph.facebook.com/v27.0/1234567/smb_app_data');assert.deepEqual(JSON.parse(calls[0].options.body),{messaging_product:'whatsapp',sync_type:'history'});assert.doesNotMatch(calls[0].url,/private/);
});
test('Ambiguous provider outcomes do not retry a single-use endpoint',async()=>{
 for(const response of[()=>{throw Error('timeout');},()=>new Response('',{status:503}),()=>Response.json({}),()=>new Response('',{status:409})]){let calls=0;const r=await requestCoexistenceSync({phone:'1234567',kind:'history',token:'private'},async()=>{calls++;return response();});assert.equal(r.state,'unknown');assert.equal(calls,1);}
 const r=await requestCoexistenceSync({phone:'1234567',kind:'history',token:'private'},async()=>new Response('',{status:403}));assert.equal(r.state,'failed');
});

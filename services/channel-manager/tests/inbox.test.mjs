import test from 'node:test';
import assert from 'node:assert/strict';
import {persistChannelEvent} from '../dist/inbox.js';
const event={externalEventId:'revision-1',payload:{type:'agoda.snapshot'}};
test('only durable insertion or an existing inbox row permits source acknowledgement',async()=>{
 let lookups=0;
 const db=(data,existing,error=null)=>({rpc:async()=>({data,error}),from(){lookups++;const q={select(){return q;},eq(){return q;},maybeSingle:async()=>({data:existing,error:null})};return q;}});
 await persistChannelEvent(db('id',null),'hotel',event);assert.equal(lookups,0);
 await persistChannelEvent(db(null,{id:'durable-id'}),'hotel',event);assert.equal(lookups,1);
 await assert.rejects(persistChannelEvent(db(null,null),'hotel',event),/source retained/);
 await assert.rejects(persistChannelEvent(db(null,null,{message:'provider raw secret'}),'hotel',event),e=>!e.message.includes('secret'));
});

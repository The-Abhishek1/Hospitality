import test from 'node:test';
import assert from 'node:assert/strict';
import { MockAdapter } from '../dist/adapters/mock.js';

test('poll preserves source events until durable-ingest acknowledgement and uses unique source IDs',async()=>{
 const rows=[{id:'event-1',connection_id:'hotel-1',payload:{type:'reservation.created'}},{id:'event-2',connection_id:'hotel-2',payload:{type:'reservation.created'}}];
 const db={from(){let remove=false;const filters={};const q={select(){return q;},delete(){remove=true;return q;},eq(k,v){filters[k]=v;return q;},order(){return q;},limit(){return q;},then(resolve){const matches=r=>Object.entries(filters).every(([k,v])=>r[k]===v);const found=rows.filter(matches);if(remove)for(const r of found)rows.splice(rows.indexOf(r),1);return Promise.resolve({data:found,error:null}).then(resolve);}};return q;}};
 const adapter=new MockAdapter(db),ctx={connectionId:'hotel-1',credentialsRef:null};
 const first=await adapter.fetchEvents(ctx);assert.equal(first.length,1);assert.equal(first[0].externalEventId,'event-1');
 assert.deepEqual(await adapter.fetchEvents(ctx),first,'failed ingest can poll same event again');
 await adapter.acknowledgeEvent(ctx,first[0]);assert.deepEqual(await adapter.fetchEvents(ctx),[]);
 assert.equal(rows.length,1);assert.equal(rows[0].connection_id,'hotel-2','ack cannot remove another hotel event');
});

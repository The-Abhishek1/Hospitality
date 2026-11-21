import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
const code=ts.transpileModule(readFileSync(new URL('../src/lib/channel-review.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const{reviewSnapshot,canLinkSnapshot,reviewPage}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const snapshot={payment_model:'property_collect',room_count:1,adults:2,children:0,status:'ConfirmBooking',check_in:'2027-01-01',check_out:'2027-01-03',currency:'INR',total_amount:'200.00'};
test('review rendering whitelists fields and never forwards raw card or credentials',()=>{
 const result=reviewSnapshot({...snapshot,card_number:'private-card',credentials:'private-secret',guest_name:'A'.repeat(500)});
 assert.equal(result.guest.length,200);assert.doesNotMatch(JSON.stringify(result),/private-card|private-secret/);
 assert.equal(reviewSnapshot(null).amount,'');
});
test('link UI is offered only for complete single-room property-collect snapshots',()=>{
 assert.equal(canLinkSnapshot(snapshot),true);
 for(const patch of [{room_count:2},{payment_model:'agoda_collect'},{review_reason:'Unsupported price'},{adults:null},{status:'CancelBooking'},{total_amount:'200.005'},{currency:'invalid'}])assert.equal(canLinkSnapshot({...snapshot,...patch}),false);
});
test('review pagination rejects invalid offsets and caps excessive pages',()=>{
 assert.equal(reviewPage('-3'),1);assert.equal(reviewPage('1.5'),1);assert.equal(reviewPage('2'),2);assert.equal(reviewPage('10000000'),10000);
});

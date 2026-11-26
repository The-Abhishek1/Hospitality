import {withDateHelpers} from './date-imports.mjs';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
const source=readFileSync(new URL('../src/lib/reservations.ts',import.meta.url),'utf8');
const {outputText}=ts.transpileModule(withDateHelpers(source),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}});
const {validDay,stayNights,normalizeFilters,validId,availableStayActions,isMissedArrival}=await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`);
test('calendar dates reject impossible dates instead of silently normalizing them',()=>{
 for(const d of ['2027-02-29','2028-02-30','2027-04-31','not-a-date','2027-1-01','2027-01-01T12:00:00Z'])assert.equal(validDay(d),false,d);
 assert.equal(validDay('2028-02-29'),true);
});
test('night counts treat checkout as exclusive across month, leap, and year boundaries',()=>{
 assert.equal(stayNights('2028-02-28','2028-03-01'),2);
 assert.equal(stayNights('2026-12-31','2027-01-01'),1);
 assert.equal(stayNights('invalid','2027-01-01'),0);
});
test('untrusted query parameters cannot create invalid dates, arbitrary statuses or enormous offsets',()=>{
 const f=normalizeFilters({start:'2027-02-31',page:'-10',room_page:'9999999999',status:'anything',source:'unknown',q:'x'.repeat(200),mode:'script'},'2027-01-01');
 assert.equal(f.start,'2027-01-01');assert.equal(f.page,1);assert.equal(f.room_page,100000);assert.equal(f.q.length,100);assert.equal(f.status,'');assert.equal(f.source,'');assert.equal(f.mode,'list');
});
test('search and archive filters survive normalization',()=>{
 const f=normalizeFilters({view:'all',q:'  Guest Name  ',status:'cancelled',mode:'calendar',page:'2',from:'2027-01-01',to:'2027-03-01'},'2027-01-01');
 assert.equal(f.view,'all');assert.equal(f.q,'Guest Name');assert.equal(f.status,'cancelled');assert.equal(f.page,2);assert.equal(f.mode,'calendar');
});
test('reservation identifiers reject malformed URL and form values',()=>{
 assert.equal(validId('ab300000-0000-0000-0000-000000000001'),true);
 for(const id of ['../../../login','',null,'x'.repeat(36)])assert.equal(validId(id),false);
});

const actionDetail=(status,rights={},source='direct',arrival='2026-11-24')=>({stay:{status,source,check_in:arrival,check_out:'2026-11-26'},can_frontdesk:true,can_write:true,can_bill:true,...rights});
test('completed, cancelled and no-show stays expose no active stay actions',()=>{
 for(const status of ['checked_out','cancelled','no_show'])assert.deepEqual(availableStayActions(actionDetail(status),'2026-11-24'),[]);
});
test('arrival and in-house states expose the appropriate primary action',()=>{
 const arrival=availableStayActions(actionDetail('confirmed'),'2026-11-24').map(a=>a.id),inHouse=availableStayActions(actionDetail('checked_in'),'2026-11-24').map(a=>a.id);
 assert.ok(arrival.includes('check_in'));assert.ok(!arrival.includes('check_out'));assert.ok(inHouse.includes('check_out'));assert.ok(!inHouse.includes('check_in'));assert.ok(!inHouse.includes('cancel'));
});
test('stay actions follow separate front desk, booking and billing permissions',()=>{
 const readonly={can_frontdesk:false,can_write:false,can_bill:false};
 assert.deepEqual(availableStayActions(actionDetail('confirmed',readonly),'2026-11-24'),[]);
 assert.deepEqual(availableStayActions(actionDetail('checked_in',{...readonly,can_bill:true}),'2026-11-24').map(a=>a.id),['post_charges']);
 assert.deepEqual(availableStayActions(actionDetail('confirmed',{...readonly,can_frontdesk:true}),'2026-11-24').map(a=>a.id),['check_in','move']);
});
test('channel cancellation and premature no-show controls are not offered',()=>{
 assert.ok(!availableStayActions(actionDetail('confirmed',{},'ota'),'2026-11-24').some(a=>a.id==='cancel'));
 assert.ok(!availableStayActions(actionDetail('confirmed',{},'direct','2026-11-25'),'2026-11-24').some(a=>a.id==='no_show'));
 assert.ok(availableStayActions(actionDetail('confirmed',{},'direct','2026-11-23'),'2026-11-24').some(a=>a.id==='no_show'));
});

test('missed-arrival labels use the hotel day and only unresolved confirmed bookings',()=>{
 assert.equal(isMissedArrival({status:'confirmed',check_in:'2026-11-23'},'2026-11-24'),true);
 for(const check_in of ['2026-11-24','2026-11-25','invalid'])assert.equal(isMissedArrival({status:'confirmed',check_in},'2026-11-24'),false);
 for(const status of ['checked_in','checked_out','cancelled','no_show'])assert.equal(isMissedArrival({status,check_in:'2026-11-23'},'2026-11-24'),false);
});
test('expired bookings offer room release while check-in needs a current booked night',()=>{
 const expired=actionDetail('confirmed');expired.stay.check_out='2026-11-24';
 const ids=availableStayActions(expired,'2026-11-24').map(a=>a.id);assert.ok(!ids.includes('check_in'));assert.ok(ids.includes('no_show'));
 assert.ok(!availableStayActions(actionDetail('confirmed',{},'direct','2026-11-25'),'2026-11-24').some(a=>a.id==='check_in'));
});

test('reservations open on the calendar while explicit list and filtered work links keep their intent',()=>{
 assert.equal(normalizeFilters({},'2026-11-24').mode,'calendar');
 assert.equal(normalizeFilters({mode:'list'},'2026-11-24').mode,'list');
 assert.equal(normalizeFilters({view:'all',status:'confirmed',to:'2026-11-23'},'2026-11-24').mode,'list');
 assert.equal(normalizeFilters({q:'Guest'},'2026-11-24').mode,'list');
 assert.equal(normalizeFilters({mode:'calendar',view:'all',q:'Guest'},'2026-11-24').mode,'calendar');
});

import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
const source=readFileSync(new URL('../src/lib/reservations.ts',import.meta.url),'utf8');
const {outputText}=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}});
const {validDay,stayNights,normalizeFilters,validId}=await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`);
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

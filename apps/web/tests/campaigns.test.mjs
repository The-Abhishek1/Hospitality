import {test}from 'node:test';import assert from 'node:assert/strict';import{readFileSync}from'node:fs';import ts from'typescript';
const code=ts.transpileModule(readFileSync(new URL('../src/lib/campaigns.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const{campaignFilters,campaignPage,campaignTime}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
test('audience filters default to past guests and bound untrusted query values',()=>{
 assert.equal(campaignFilters(null).status,'checked_out');assert.equal(campaignFilters({status:'cancelled',source:'malformed'}).source,'all');assert.equal(campaignFilters({q:' x '.repeat(100)}).q.length,100);
 assert.equal(campaignFilters({from:'2025-05-01',to:'2025-08-31',status:'all',source:'ota'}).source,'ota');
});
test('campaign schedules display in the hotel timezone rather than browser/server timezone',()=>{
 const shown=campaignTime('2026-11-17T18:30:00Z','Asia/Kolkata');assert.match(shown,/18/);assert.match(shown,/12:00/);
 assert.equal(campaignPage('-1'),1);assert.equal(campaignPage('1.5'),1);assert.equal(campaignPage('999999'),10000);
});

import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
const code=ts.transpileModule(readFileSync(new URL('../src/lib/distribution-catalog.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {distributionChannels,filterDistribution}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
test('brand aliases resolve to one integration route without implying shared Vrbo certification',()=>{
 assert.equal(filterDistribution('Hotels.com')[0].key,'expedia');
 assert.equal(filterDistribution('Goibibo')[0].key,'makemytrip');
 assert.equal(filterDistribution('Galileo')[0].key,'travelport');
 assert.equal(filterDistribution('Vrbo')[0].key,'vrbo');
});
test('metasearch is distinct from OTA supply and planned entries have no setup action',()=>{
 assert.deepEqual(filterDistribution('trivago','ota'),[]);
 assert.equal(filterDistribution('Trivago','metasearch')[0].key,'trivago');
 assert.deepEqual(distributionChannels.filter(c=>c.setup).map(c=>c.key).sort(),['agoda','booking_com','makemytrip']);
 assert.ok(distributionChannels.filter(c=>c.status==='planned').every(c=>!c.setup));
});
test('catalog filters trim queries, combine categories and return no results for unknown brands',()=>{
 assert.equal(filterDistribution('  AGODA ')[0].key,'agoda');
 assert.deepEqual(filterDistribution('not-a-real-channel'),[]);
 assert.equal(new Set(distributionChannels.map(c=>c.key)).size,distributionChannels.length);
});

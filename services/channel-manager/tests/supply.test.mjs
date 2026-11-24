import test from 'node:test';
import assert from 'node:assert/strict';
import { SupplyAdapter, availabilityXml, parseXml } from '../dist/adapters/supply.js';
const ctx={connectionId:'c',credentialsRef:'secret-ref',externalPropertyId:'123',environment:'sandbox'};
const push={externalRoomId:'456',days:[{day:'2027-01-15',available:2},{day:'2027-01-16',available:0}]};
const creds=provider=>({provider,environment:'sandbox',clientId:'client',clientSecret:'DO_NOT_LOG'});
const jwt='header.'+Buffer.from(JSON.stringify({test:true})).toString('base64url')+'.signature';
test('provider XML respects each date format and preserves manual closures',()=>{
 const a=availabilityXml('agoda','123',push),b=availabilityXml('booking_com','123',push);
 assert.match(a,/<date_range from="2027-01-15" to="2027-01-15"/);
 assert.match(b,/<date value="2027-01-16"><roomstosell>0/);
 assert.doesNotMatch(a+b,/<closed>/);
 assert.throws(()=>availabilityXml('booking_com','123',{...push,days:[{day:'2027-01-01',available:255}]}));
 for(const bad of ['2027-02-30','invalid']) assert.throws(()=>availabilityXml('agoda','123',{...push,days:[{day:bad,available:1}]}));
 assert.throws(()=>availabilityXml('agoda','123',{...push,externalRoomId:'123" injected="1'}));
 assert.throws(()=>availabilityXml('agoda','123',{...push,days:[push.days[0],push.days[0]]}));
});
test('XML rejects malformed responses and external entities',()=>{
 assert.throws(()=>parseXml('<!DOCTYPE x [<!ENTITY x SYSTEM "file:///etc/passwd">]><ok/>'));
 assert.throws(()=>parseXml('<result>'));
});
for(const provider of ['agoda','booking_com']) {
 test(`${provider}: OAuth, documented endpoint, cached token, success`,async()=>{
  const calls=[];
  const http=async(url,init)=>{calls.push({url,init});return new Response(calls.length===1?JSON.stringify(provider==='agoda'?{access_token:'private-token',expires_in:3600}:{jwt}):(provider==='agoda'?'<result TUID="trace"/>':'<ok/>'),{status:200});};
  const adapter=new SupplyAdapter(provider,()=>creds(provider),true,http);
  await adapter.pushAvailability(ctx,push);await adapter.pushAvailability(ctx,push);
  assert.equal(calls.length,3);assert.equal(calls[0].init.redirect,'error');
  assert.equal(calls[1].url,provider==='agoda'?'https://sandbox-supply.agoda.com/api/v2/ari':'https://supply-xml.booking.com/hotels/xml/availability');
  assert.match(calls[1].init.headers.Authorization,/^Bearer /);
  if(provider==='agoda')assert.match(calls[0].init.body,/grant_type=client_credentials/);
 });
 test(`${provider}: disabled traffic never calls network`,async()=>{
  const adapter=new SupplyAdapter(provider,()=>creds(provider),false,async()=>{throw new Error('network should not be called');});
  await assert.rejects(adapter.pushAvailability(ctx,push),/disabled/);
 });
 test(`${provider}: rejects partial / semantic errors and never logs provider body`,async()=>{
  for (const [status,body] of [[207,'private body'],[200,'<result TUID="trace"><errors><error>private</error></errors></result>'],[200,'<html>private</html>']]) {
   let n=0;const adapter=new SupplyAdapter(provider,()=>creds(provider),true,async()=>new Response(n++===0?JSON.stringify(provider==='agoda'?{access_token:'token',expires_in:3600}:{jwt}):body,{status:n===1?200:status}));
   await assert.rejects(adapter.pushAvailability(ctx,push),e=>!e.message.includes('private'));
  }
 });
 test(`${provider}: 401 refreshes token once`,async()=>{
  let auth=0,pushes=0;
  const adapter=new SupplyAdapter(provider,()=>creds(provider),true,async(url)=>{
   if(url.includes('exchange')){auth++;return Response.json(provider==='agoda'?{access_token:'token'+auth,expires_in:3600}:{jwt});}
   pushes++;return new Response(provider==='agoda'?'<result TUID="trace"/>':'<ok/>',{status:pushes===1?401:200});
  });
  await adapter.pushAvailability(ctx,push);assert.equal(auth,2);assert.equal(pushes,2);
 });
}
test('Booking.com rejects production machine account before sending availability',async()=>{
 let calls=0;const adapter=new SupplyAdapter('booking_com',()=>creds('booking_com'),true,async()=>{calls++;return Response.json({jwt:'a.'+Buffer.from('{"test":false}').toString('base64url')+'.c'});});
 await assert.rejects(adapter.pushAvailability(ctx,push),/test machine account/);assert.equal(calls,1);
});
test('Agoda refreshes an expired HTTP 403 token once and retries the same property update',async()=>{
 const calls=[];let auth=0;
 const adapter=new SupplyAdapter('agoda',()=>creds('agoda'),true,async(url,init)=>{
  calls.push({url,init});
  if(url.includes('exchange'))return Response.json({access_token:'token'+(++auth),expires_in:3600});
  return new Response('<result TUID="accepted"/>',{status:init.headers.Authorization==='Bearer token1'?403:200});
 });
 await adapter.pushAvailability(ctx,push);
 const updates=calls.filter(c=>!c.url.includes('exchange'));
 assert.equal(auth,2);assert.equal(updates.length,2);
 assert.equal(updates[0].url,updates[1].url);assert.equal(updates[0].init.body,updates[1].init.body);
 assert.equal(updates[1].init.headers.Authorization,'Bearer token2');
 await adapter.pushAvailability(ctx,push);assert.equal(auth,2,'later updates reuse the refreshed token');
});
test('Agoda permanent HTTP 403 denial stops after one refresh without exposing response secrets',async()=>{
 let auth=0,updates=0;
 const adapter=new SupplyAdapter('agoda',()=>creds('agoda'),true,async(url)=>{
  if(url.includes('exchange')){auth++;return Response.json({access_token:'private-token',expires_in:3600});}
  updates++;return new Response('private account details DO_NOT_LOG',{status:403});
 });
 await assert.rejects(adapter.pushAvailability(ctx,push),error=>error.message==='agoda: supply HTTP 403');
 assert.equal(auth,2);assert.equal(updates,2);
});
test('Booking.com HTTP 403 is not treated as an Agoda token-expiry response',async()=>{
 let auth=0,updates=0;
 const adapter=new SupplyAdapter('booking_com',()=>creds('booking_com'),true,async(url)=>{
  if(url.includes('exchange')){auth++;return Response.json({jwt});}
  updates++;return new Response('forbidden',{status:403});
 });
 await assert.rejects(adapter.pushAvailability(ctx,push),/supply HTTP 403/);
 assert.equal(auth,1);assert.equal(updates,1);
});

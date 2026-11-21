import test from 'node:test';
import assert from 'node:assert/strict';
import { AgodaAdapter, normalizeProducts, normalizeBooking, rateXml } from '../dist/adapters/agoda.js';
import {parseXml} from '../dist/adapters/supply.js';
const productsXml='<result><property id="123" currency="INR" occupancy_model="Full Rate"><rooms><room room_id="456" room_name="Double" num_persons="2" min_rate="10.00" max_rate="10000.00"/></rooms><rateplans><rateplan rateplan_id="789" rateplan_name="Room" master_rate="0" rate_type="Sell" tax_included="1"/></rateplans><products><product room_id="456" rateplan_id="789"/></products></property></result>';
const products=normalizeProducts(parseXml(productsXml),'123');
const booking=(attrs='',extra='')=>parseXml(`<booking property_id="123" booking_id="9001" last_action="2026-11-17T12:00:00+05:30" status="ConfirmBooking" room_id="456" arrival="2027-02-01" departure="2027-02-03" room_count="1" adults="2" children="0" extrabeds="0" ${attrs}><customer first_name="Asha" last_name="Test"/><prices currency="INR" sell_inclusive_amt="1000.05" net_inclusive_amt="900.00"/><paymentmodel>2</paymentmodel>${extra}</booking>`).booking;
const ctx={connectionId:'test',credentialsRef:'test',externalPropertyId:'123',environment:'sandbox'};
const rate={externalRoomId:'456',externalRateId:'789',currency:'INR',days:[{day:'2027-02-01',amount:'100.05',closed:null,cta:true,ctd:false,minLos:2,maxLos:5}]};
test('products map exact hotel, rooms, master rate and room/rate pairs',()=>{
 assert.equal(products.rooms[0].id,'456');assert.equal(products.rates[0].master,'0');assert.equal(products.currency,'INR');
 assert.throws(()=>normalizeProducts(parseXml(productsXml),'999'),/hotel/);
});
test('rates encode exact price and explicit restrictions, preserving unspecified closure',()=>{
 const xml=rateXml('123',rate,products);assert.match(xml,/<normal default="100.05"/);assert.match(xml,/<cta>true<\/cta>/);assert.match(xml,/<min>2<\/min><max>5<\/max>/);assert.doesNotMatch(xml,/<closed>/);
 for(const invalid of [{...rate,currency:'USD'},{...rate,externalRateId:'999'},{...rate,days:[{...rate.days[0],amount:'1.00'}]},{...rate,days:[{...rate.days[0],amount:'100.001'}]},{...rate,days:[{...rate.days[0],minLos:10,maxLos:2}]}])assert.throws(()=>rateXml('123',invalid,products));
 assert.throws(()=>rateXml('123',rate,{...products,rates:[{...products.rates[0],master:'22'}]}),/derived/);
});
test('bookings have stable revision IDs and whitelist sensitive payment/card data out',()=>{
 const b=booking('', '<payment card_number="4111111111111111" card_cvv="123"/>');const event=normalizeBooking(b,'123');
 assert.equal(event.payload.total_amount,'1000.05');assert.equal(event.payload.currency,'INR');assert.equal(event.payload.payment_model,'property_collect');assert.equal(event.payload.revision,'2026-11-17T06:30:00.000Z');
 assert.equal(event.externalEventId,normalizeBooking(b,'123').externalEventId);assert.doesNotMatch(JSON.stringify(event),/4111111111111111|card_cvv|card_number/);
 assert.throws(()=>normalizeBooking(b,'999'),/another hotel/);
});
test('Agoda Collect preserves net amount as a distinct basis, never as property-collect guest debt',()=>{
 const b=booking();b.paymentmodel='1';const e=normalizeBooking(b,'123');assert.equal(e.payload.total_amount,'900.00');assert.equal(e.payload.amount_basis,'net_inclusive_amt');assert.equal(e.payload.payment_model,'agoda_collect');
});
test('unsupported amounts / extra beds are durable review events, not dropped or silently converted',()=>{
 const b=booking();b.prices['@_sell_inclusive_amt']='100.005';const e=normalizeBooking(b,'123');assert.match(e.payload.review_reason,/precision/);
 const extra=booking();extra['@_extrabeds']='1';assert.match(normalizeBooking(extra,'123').payload.review_reason,/Extra-bed/);
});
function adapterWith(replies) {
 const calls=[];const http=async(url,init)=>{calls.push({url,init});if(url.includes('exchange'))return Response.json({access_token:'private',expires_in:3600});const reply=replies.shift();if(reply===undefined)throw new Error('Unexpected request');return new Response(reply,{status:200});};
 return {adapter:new AgodaAdapter(()=>({provider:'agoda',environment:'sandbox',clientId:'test',clientSecret:'secret'}),true,http),calls};
}
test('booking list/details are pulled for one scoped property and normalized',async()=>{
 const list='<result><properties count="1"><property id="123"><bookings><booking booking_id="9001" last_action="2026-11-17T12:00:00+05:30"/></bookings></property></properties></result>';
 const details='<result><bookings count="1">'+`<booking property_id="123" booking_id="9001" last_action="2026-11-17T12:00:00+05:30" status="CancelBooking"><prices currency="INR" sell_inclusive_amt="0.00"/><paymentmodel>2</paymentmodel></booking>`+'</bookings></result>';
 const {adapter,calls}=adapterWith([list,details]);const events=await adapter.fetchReservationWindow(ctx,'2026-11-17T06:00:00Z','2026-11-17T06:55:00Z');
 assert.equal(events.length,1);assert.equal(events[0].payload.status,'CancelBooking');assert.match(calls[1].init.body,/type="3"/);assert.match(calls[2].init.body,/type="4"/);assert.match(calls[2].init.body,/<booking id="9001"/);
 assert.ok(calls.slice(1).every(c=>c.url==='https://sandbox-supply.agoda.com/api'));
});
test('missing details, cross-property lists and invalid windows fail without advancing a checkpoint',async()=>{
 const list='<result><properties><property id="123"><bookings><booking booking_id="9001" last_action="2026-11-17T06:30:00Z"/></bookings></property></properties></result>';
 const {adapter}=adapterWith([list,'<result><bookings count="0"/></result>']);await assert.rejects(adapter.fetchReservationWindow(ctx,'2026-11-17T06:00:00Z','2026-11-17T06:55:00Z'),/Missing Agoda/);
 const wrong=adapterWith(['<result><properties><property id="999"/></properties></result>']);await assert.rejects(wrong.adapter.fetchReservationWindow(ctx,'2026-11-17T06:00:00Z','2026-11-17T06:55:00Z'),/another hotel/);
 await assert.rejects(adapter.fetchReservationWindow(ctx,'2026-11-17T06:00:00Z','2026-11-17T08:00:00Z'),/60 minutes/);
});
test('product and rate methods use sandbox transport and reject partial acceptance',async()=>{
 const {adapter,calls}=adapterWith([productsXml,'<result TUID="trace" status="PartialSuccess"/>']);const p=await adapter.fetchProducts(ctx);assert.equal(p.currency,'INR');await assert.rejects(adapter.pushRates(ctx,rate,p),/partially/);assert.match(calls[1].init.body,/type="5"/);
});

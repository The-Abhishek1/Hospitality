import { createHash } from 'node:crypto';
import { SupplyAdapter, identifier, validateDays, assertAgodaAccepted, type SupplyCredentials, type Fetch } from './supply.js';
import type { ConnectionCtx, NormalizedEvent } from '../adapter.js';
const list = (value:any):any[] => value == null || value === '' ? [] : Array.isArray(value) ? value : [value];
const str = (value:any, max=200):string => typeof value === 'string' ? value.slice(0,max) : '';
export function day(value:string):string {
 if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || !Number.isFinite(Date.parse(value)) || new Date(value).toISOString().slice(0,10)!==value) throw new Error('Invalid Agoda date');
 return value;
}
export function timestamp(value:string):string {
 if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(Date.parse(value))) throw new Error('Invalid Agoda revision timestamp');
 return new Date(value).toISOString();
}
export function money(value:unknown):string {
 if(typeof value!=='string'||!/^\d{1,9}(?:\.\d{1,2})?$/.test(value)) throw new Error('Unsupported Agoda amount precision or missing amount');
 const [whole,fraction='']=value.split('.'); return `${BigInt(whole)}.${fraction.padEnd(2,'0')}`;
}
function integer(v:any,min:number,max:number):number {
 if(typeof v!=='string'||!/^\d+$/.test(v)||Number(v)<min||Number(v)>max)throw new Error('Invalid Agoda booking occupancy');
 return Number(v);
}
export type AgodaProducts = {hotelId:string;currency:string;occupancyModel:string;rooms:{id:string;name:string;capacity:number;minRate:string;maxRate:string}[];rates:{id:string;name:string;master:string;rateType:string;taxIncluded:boolean}[];products:{roomId:string;rateId:string}[]};
export function normalizeProducts(xml:Record<string,any>, hotel:string):AgodaProducts {
 const p=xml.result?.property;
 if(!p||Array.isArray(p)||p['@_id']!==identifier(hotel)||!/^[A-Z]{3}$/.test(p['@_currency']??''))throw new Error('Agoda products do not match requested hotel');
 const out:AgodaProducts={hotelId:hotel,currency:p['@_currency'],occupancyModel:str(p['@_occupancy_model']),
  rooms:list(p.rooms?.room).map(r=>({id:identifier(r['@_room_id']),name:str(r['@_room_name']),capacity:integer(r['@_num_persons'],1,99),minRate:money(r['@_min_rate']),maxRate:money(r['@_max_rate'])})),
  rates:list(p.rateplans?.rateplan).map(r=>({id:identifier(r['@_rateplan_id']),name:str(r['@_rateplan_name']),master:str(r['@_master_rate']),rateType:str(r['@_rate_type']),taxIncluded:r['@_tax_included']==='1'})),
  products:list(p.products?.product).map(r=>({roomId:identifier(r['@_room_id']),rateId:identifier(r['@_rateplan_id'])}))};
 if(!out.rooms.length||!out.rates.length||out.products.some(x=>!out.rooms.some(r=>r.id===x.roomId)||!out.rates.some(r=>r.id===x.rateId)))throw new Error('Incomplete Agoda product catalog');
 return out;
}
export type AgodaRateDay={day:string;amount:string;closed:boolean|null;cta:boolean|null;ctd:boolean|null;minLos:number|null;maxLos:number|null};
export type AgodaRatePush={externalRoomId:string;externalRateId:string;currency:string;days:AgodaRateDay[]};
export function rateXml(hotel:string,push:AgodaRatePush,products:AgodaProducts):string {
 identifier(hotel);identifier(push.externalRateId);validateDays({externalRoomId:push.externalRoomId,days:push.days.map(d=>({day:d.day,available:0}))},999);
 if(hotel!==products.hotelId||push.currency!==products.currency)throw new Error('Agoda currency / hotel mismatch');
 const room=products.rooms.find(r=>r.id===push.externalRoomId),rate=products.rates.find(r=>r.id===push.externalRateId);
 if(!room||!rate||rate.master!=='0'||!products.products.some(p=>p.roomId===room.id&&p.rateId===rate.id))throw new Error('Unmapped or derived Agoda room-rate product');
 const cents=(s:string)=>BigInt(money(s).replace('.',''));
 return `<request timestamp="${Date.now()}" type="10"><criteria property_id="${hotel}"><rate>${push.days.map(d=>{
  const amount=money(d.amount);
  if(cents(amount)<cents(room.minRate)||cents(amount)>cents(room.maxRate))throw new Error('Rate outside Agoda room price limits');
  for(const v of [d.closed,d.cta,d.ctd])if(v!==null&&typeof v!=='boolean')throw new Error('Invalid restriction flag');
  if(d.minLos!==null&&(!Number.isInteger(d.minLos)||d.minLos<1||d.minLos>99))throw new Error('Invalid minimum length of stay');
  if(d.maxLos!==null&&(!Number.isInteger(d.maxLos)||d.maxLos<0||d.maxLos>99||(d.maxLos>0&&d.minLos!==null&&d.maxLos<d.minLos)))throw new Error('Invalid maximum length of stay');
  const flags=([['closed',d.closed],['cta',d.cta],['ctd',d.ctd]] as const).filter(([,v])=>v!==null).map(([k,v])=>`<${k}>${v}</${k}>`).join('');
  const los=(d.minLos===null?'':`<min>${d.minLos}</min>`)+(d.maxLos===null?'':`<max>${d.maxLos}</max>`);
  return `<update room_id="${room.id}" rateplan_id="${rate.id}"><date_range from="${d.day}" to="${d.day}"/><prices currency="${push.currency}"><normal default="${amount}"/></prices>${flags||los?`<restrictions>${flags}${los?`<los>${los}</los>`:''}</restrictions>`:''}</update>`;
 }).join('')}</rate></criteria></request>`;
}
export function normalizeBooking(b:any,hotel:string):NormalizedEvent {
 if(b['@_property_id']!==identifier(hotel))throw new Error('Agoda booking belongs to another hotel');
 const id=identifier(b['@_booking_id']),revision=timestamp(b['@_last_action']),status=str(b['@_status']);
 if(!['ConfirmBooking','AmendBooking','CancelBooking'].includes(status))throw new Error('Unknown Agoda booking status');
 // Explicit whitelist: card/VCC/payment XML is never persisted or logged.
 const payload:Record<string,unknown>={type:'agoda.snapshot',external_reservation_id:id,revision,status,external_property_id:hotel};
 let reason:string|null=null;
 try {
  const prices=b.prices,model=b.paymentmodel==='2'?'property_collect':b.paymentmodel==='1'||b.paymentmodel==null?'agoda_collect':'unknown';
  payload.payment_model=model;
  const field=model==='property_collect'?'sell_inclusive_amt':'net_inclusive_amt';
  if(model==='unknown')throw new Error('Unsupported payment model');
  payload.amount_basis=field;
  payload.currency=str(prices?.['@_currency'],3);
  if(!/^[A-Z]{3}$/.test(String(payload.currency)))throw new Error('Missing booking currency');
  payload.total_amount=money(prices?.['@_'+field]);
  if(status!=='CancelBooking') {
   payload.external_room_id=identifier(b['@_room_id']);
   payload.check_in=day(b['@_arrival']);payload.check_out=day(b['@_departure']);
   if(String(payload.check_out)<=String(payload.check_in))throw new Error('Invalid booking date range');
   payload.room_count=integer(b['@_room_count'],1,20);
   payload.adults=integer(b['@_adults'],1,200);payload.children=integer(b['@_children'],0,200);
   if(b['@_extrabeds']&&b['@_extrabeds']!=='0')throw new Error('Extra-bed booking needs staff review');
   payload.guest_name=[str(b.customer?.['@_first_name'],100),str(b.customer?.['@_last_name'],100)].filter(Boolean).join(' ')||'Agoda guest';
   payload.guest_phone=str(b.customer?.['@_phone'],40)||null;payload.guest_email=str(b.customer?.['@_email'],254)||null;
  }
 } catch(e) {reason=e instanceof Error?e.message:'Unsupported Agoda booking shape';}
 if(reason)payload.review_reason=reason;
 return {externalEventId:'agoda:'+id+':'+createHash('sha256').update(revision+':'+status).digest('hex').slice(0,32),payload};
}
export class AgodaAdapter extends SupplyAdapter {
 constructor(resolve:(ref:string)=>SupplyCredentials,enabled:boolean,http:Fetch=fetch){super('agoda',resolve,enabled,http);}
 async fetchProducts(ctx:ConnectionCtx):Promise<AgodaProducts>{
  const hotel=identifier(ctx.externalPropertyId);
  return normalizeProducts(await this.xmlRequest(ctx,'/api',`<request type="5" timestamp="${Date.now()}"><criteria language="EN"><property id="${hotel}"><rooms/><rateplans/></property></criteria></request>`),hotel);
 }
 async pushRates(ctx:ConnectionCtx,push:AgodaRatePush,products:AgodaProducts):Promise<void>{
  assertAgodaAccepted(await this.xmlRequest(ctx,'/api/v2/ari',rateXml(identifier(ctx.externalPropertyId),push,products)));
 }
 async fetchReservationWindow(ctx:ConnectionCtx,from:string,to:string):Promise<NormalizedEvent[]>{
  const hotel=identifier(ctx.externalPropertyId),start=timestamp(from),end=timestamp(to);
  if(Date.parse(end)<=Date.parse(start)||Date.parse(end)-Date.parse(start)>60*60*1000)throw new Error('Agoda polling window must be positive and at most 60 minutes');
  const response=await this.xmlRequest(ctx,'/api',`<request type="3" timestamp="${Date.now()}"><criteria from="${start}" to="${end}"><property id="${hotel}"/></criteria></request>`);
  if(!response.result?.properties)throw new Error('Incomplete Agoda booking list');
  const properties=list(response.result.properties.property);
  if(properties.some(p=>p['@_id']!==hotel))throw new Error('Agoda list contains another hotel');
  const entries=properties.flatMap(p=>list(p.bookings?.booking));
  const ids=[...new Set(entries.map(b=>identifier(b['@_booking_id'])))];
  const events:NormalizedEvent[]=[];
  for(let i=0;i<ids.length;i+=50){
   const batch=ids.slice(i,i+50);
   const details=await this.xmlRequest(ctx,'/api',`<request type="4" timestamp="${Date.now()}"><criteria language="EN"><property id="${hotel}">${batch.map(id=>`<booking id="${id}"/>`).join('')}</property></criteria></request>`);
   if(!details.result?.bookings)throw new Error('Incomplete Agoda booking detail response');
   const bookings=list(details.result.bookings.booking);
   if(bookings.some(b=>!batch.includes(b['@_booking_id'])))throw new Error('Unexpected Agoda booking detail');
   for(const id of batch){
    const b=bookings.find(b=>b['@_booking_id']===id);
    if(!b)throw new Error('Missing Agoda booking detail; polling cursor retained');
    const event=normalizeBooking(b,hotel);
    const listed=entries.filter(x=>x['@_booking_id']===id);
    if(listed.some(x=>Date.parse(timestamp(x['@_last_action']))>Date.parse(String(event.payload.revision))))throw new Error('Stale Agoda detail; polling cursor retained');
    events.push(event);
   }
  }
  return events;
 }
}

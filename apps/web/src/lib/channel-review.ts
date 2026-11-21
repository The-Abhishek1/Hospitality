export function reviewSnapshot(payload: unknown) {
 const p=payload&&typeof payload==='object'&&!Array.isArray(payload)?payload as Record<string,unknown>:{};
 const text=(key:string,max=200)=>typeof p[key]==='string'?(p[key] as string).slice(0,max):'';
 const number=(key:string)=>typeof p[key]==='number'&&Number.isSafeInteger(p[key])?p[key] as number:null;
 return {booking:text('external_reservation_id',20),status:text('status',40),revision:text('revision',60),hotel:text('external_property_id',20),room:text('external_room_id',20),guest:text('guest_name',200),arrival:text('check_in',10),departure:text('check_out',10),adults:number('adults'),children:number('children'),roomCount:number('room_count'),currency:text('currency',3),amount:text('total_amount',40),basis:text('amount_basis',40),payment:text('payment_model',40),reason:text('review_reason',500)};
}
export function canLinkSnapshot(payload: unknown): boolean {
 const s=reviewSnapshot(payload);
 return s.payment==='property_collect'&&s.roomCount===1&&!s.reason&&['ConfirmBooking','AmendBooking'].includes(s.status)&&s.adults!==null&&s.children!==null&&s.adults>0&&s.children>=0&&/^\d{4}-\d{2}-\d{2}$/.test(s.arrival)&&/^\d{4}-\d{2}-\d{2}$/.test(s.departure)&&/^[A-Z]{3}$/.test(s.currency)&&/^\d{1,9}\.\d{2}$/.test(s.amount);
}
export function reviewPage(value:unknown):number {
 const n=Number(value);return Number.isSafeInteger(n)&&n>0?Math.min(n,10000):1;
}

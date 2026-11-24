export const reservationStatuses=['confirmed','checked_in','checked_out','cancelled','no_show'] as const;
export const statusLabel=(value:string)=>({confirmed:'Confirmed',checked_in:'In house',checked_out:'Checked out',cancelled:'Cancelled',no_show:'No-show'}[value]??value.replaceAll('_',' '));
export const validDay=(value:unknown):value is string=>typeof value==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(value)&&value>='2000-01-01'&&value<='2100-12-31'&&!Number.isNaN(Date.parse(value))&&new Date(value).toISOString().slice(0,10)===value;
export const validId=(value:unknown):value is string=>typeof value==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export const stayNights=(from:string,to:string)=>validDay(from)&&validDay(to)?Math.round((Date.parse(to)-Date.parse(from))/86400000):0;
export const money=(amount:number|string,currency:string)=>new Intl.NumberFormat('en-IN',{style:'currency',currency,maximumFractionDigits:2}).format(Number(amount));
export const dayLabel=(date:string)=>new Intl.DateTimeFormat('en',{day:'numeric',month:'short',year:'numeric',timeZone:'UTC'}).format(new Date(`${date}T12:00:00Z`));
export type ReservationFilters={q:string;status:string;source:string;view:string;from:string;to:string;start:string;page:number;room_page:number;mode:string};
export function normalizeFilters(input:Record<string,string|undefined>,today:string):ReservationFilters{
 const page=(v:string|undefined)=>v&&/^\d+$/.test(v)?Math.min(100000,Math.max(1,Number(v))):1;
 return {q:(input.q??'').trim().slice(0,100),status:reservationStatuses.includes(input.status as typeof reservationStatuses[number])?input.status!:'',source:['direct','walk_in','ota'].includes(input.source??'')?input.source!:'',view:['arrivals','departures','in_house','all','upcoming'].includes(input.view??'')?input.view!:'upcoming',from:validDay(input.from)?input.from:'',to:validDay(input.to)?input.to:'',start:validDay(input.start)?input.start:today,page:page(input.page),room_page:page(input.room_page),mode:input.mode==='calendar'?'calendar':'list'};
}
export type RoomType={id:string;name:string;max_occupancy:number;base_rate:number};
export type RatePlan={id:string;name:string;adjustment_percent:number};
export type Quote={total:number;nights:number;rooms:{id:string;name:string;housekeeping_status:string}[]};
export type StayRow={id:string;version:number;full_name:string|null;phone:string|null;status:string;source:string;check_in:string;check_out:string;adults:number;children:number;total_amount:number;currency:string;room:string|null;type_name:string|null};
export type CalendarRoom={id:string;name:string;type_id:string;type_name:string;housekeeping_status:string;holds:{id:string;during:string;kind:string;reservation_id:string|null;guest:string|null;status:string|null;reason:string|null}[]};
export type ReservationWorkspace={day:string;start:string;total:number;page:number;rows:StayRow[];stats:{arrivals:number;departures:number;in_house:number;upcoming:number};can_write:boolean;can_frontdesk:boolean;room_total:number;room_page:number;calendar:CalendarRoom[]};
export type Stay={id:string;property_id:string;guest_id:string;version:number;status:string;source:string;check_in:string;check_out:string;adults:number;children:number;total_amount:number;currency:string;notes:string;rate_plan_id:string|null;channel_ref:string|null;created_at:string};
export type Detail={stay:Stay;guest:{id:string;profile_version:number;full_name:string;phone:string|null;email:string|null};room:{id:string;name:string;type_id:string;type_name:string;housekeeping_status:string;active:boolean}|null;events:{event_type:string;created_at:string;details:Record<string,unknown>}[];can_write:boolean;can_frontdesk:boolean;can_bill:boolean;can_finance:boolean;can_portal:boolean;finance?:{folio_id:string|null;folio_status:string|null;posted:number;paid:number;refunded:number;credited?:number;balance:number;unposted_room:number;checkout_balance:number}};
export function availableStayActions(detail:Pick<Detail,'stay'|'can_frontdesk'|'can_write'|'can_bill'>,today:string){
 const r=detail.stay;
 return [
  ...(detail.can_frontdesk&&r.status==='confirmed'?[{id:'check_in',label:'Check in guest'}]:[]),
  ...(detail.can_frontdesk&&r.status==='checked_in'?[{id:'check_out',label:'Check out guest'}]:[]),
  ...(detail.can_frontdesk&&['confirmed','checked_in'].includes(r.status)?[{id:'move',label:'Move room'}]:[]),
  ...(detail.can_bill&&r.status==='checked_in'?[{id:'post_charges',label:'Post booked room charges'}]:[]),
  ...(detail.can_write&&r.status==='confirmed'&&r.source!=='ota'?[{id:'cancel',label:'Cancel reservation'}]:[]),
  ...(detail.can_write&&r.status==='confirmed'&&r.check_in<=today?[{id:'no_show',label:'Mark as no-show'}]:[]),
 ];
}

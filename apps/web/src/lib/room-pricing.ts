import {validDay,stayNights} from './reservations';
export const pricingWeekdays=[{day:1,label:'Mon'},{day:2,label:'Tue'},{day:3,label:'Wed'},{day:4,label:'Thu'},{day:5,label:'Fri'},{day:6,label:'Sat'},{day:0,label:'Sun'}];
export function pricingDays(from:string,to:string,mask:number){
 if(!validDay(from)||!validDay(to)||stayNights(from,to)<0||stayNights(from,to)>365||!Number.isInteger(mask)||mask<1||mask>127)return [];
 return Array.from({length:stayNights(from,to)+1},(_,i)=>new Date(Date.parse(from)+i*86400000)).filter(d=>(mask&(1<<d.getUTCDay()))!==0).map(d=>d.toISOString().slice(0,10));
}
export function pricingStart(value:unknown){return validDay(value)&&value<='2100-12-18'?value:undefined;}
export function addPricingDays(day:string,count:number){return new Date(Date.parse(day)+count*86400000).toISOString().slice(0,10);}
export type NightlyPrice={night:string;amount:number;custom:boolean;label:string};
export type RoomPricingWorkspace={day:string;latest:string;start:string;page:number;total:number;version:number;currency:string;timezone:string;types:{id:string;name:string;base_rate:number}[];rows:{id:string;name:string;base_rate:number;days:NightlyPrice[]}[];history:{created_at:string;actor_name:string|null;payload:{type:string;from:string;to:string;weekdays:number;amount:number|null;reset:boolean;label:string};result:{nights:number;version:number;reset:boolean}}[]};

import {validDay,validId,stayNights,type StayRow} from './reservations';
import {validEmail} from './auth';
export type GroupRoom={key:string;type_id:string;rate_id:string;unit_id:string;adults:number;children:number;guest_id:string;name:string;phone:string;email:string;same_guest:boolean;contact_permission:boolean;contact_evidence:string;quote?:number};
export type GroupQuote={rows:{unit_id:string;room:string;housekeeping_status:string;quote:number}[];total:number;nights:number};
export type GroupDetail={group:{id:string;name:string;mode:string;check_in:string;check_out:string;room_count:number;notes:string;initial_results:{id:string;status:string;admission_error?:string}[]};can_frontdesk:boolean;can_book:boolean;rows:StayRow[]};
export const groupQuoteKey=(arrival:string,departure:string,mode:string,rooms:GroupRoom[])=>JSON.stringify([arrival,departure,mode,rooms.map(r=>[r.type_id,r.rate_id,r.unit_id,r.adults,r.children])]);
export function parseGroupRooms(raw:string,reviewed=false):{rooms?:GroupRoom[];error?:string}{
 if(raw.length>200000)return{error:'This group is too large. Use up to 50 rooms.'};
 try{const items=JSON.parse(raw);if(!Array.isArray(items)||items.length<2||items.length>50)return{error:'Add between 2 and 50 rooms.'};
 const rooms:GroupRoom[]=[];
 for(const[index,r]of items.entries()){
  if(!r||typeof r!=='object'||!validId(r.type_id)||(r.rate_id&&!validId(r.rate_id))||(r.unit_id&&!validId(r.unit_id))||!Number.isInteger(r.adults)||r.adults<1||r.adults>100||!Number.isInteger(r.children)||r.children<0||r.children>100)return{error:`Check the room type and guest count for room ${index+1}.`};
  if(typeof r.same_guest!=='boolean'||typeof r.contact_permission!=='boolean'||r.same_guest&&index===0||r.same_guest&&r.contact_permission)return{error:`Choose the guest and permission for room ${index+1}.`};
  if(r.guest_id&&!validId(r.guest_id))return{error:`Choose a valid guest for room ${index+1}.`};
  if(['name','phone','email','contact_evidence'].some(k=>typeof r[k]!=='string'))return{error:`Check the guest details for room ${index+1}.`};
  if(reviewed&&!r.same_guest&&!r.guest_id&&(r.name.trim().length<2||r.name.length>120||r.phone.length>40||r.email.length>254||r.email&&!validEmail(r.email)))return{error:`Enter valid guest details for room ${index+1}.`};
  if(reviewed&&r.contact_permission&&(r.contact_evidence.trim().length<10||r.contact_evidence.length>1000||!r.guest_id&&!r.phone.trim()))return{error:`Record verified contact permission and its source for room ${index+1}.`};
  if(reviewed&&(!r.unit_id||!Number.isFinite(r.quote)||r.quote<0))return{error:'Check availability and review the room prices before confirming.'};
  rooms.push({key:String(r.key??index).slice(0,80),type_id:r.type_id,rate_id:r.rate_id||'',unit_id:r.unit_id||'',adults:r.adults,children:r.children,guest_id:r.guest_id||'',name:r.name.trim(),phone:r.phone.trim(),email:r.email.trim(),same_guest:r.same_guest,contact_permission:r.contact_permission,contact_evidence:r.contact_evidence.trim(),...(reviewed?{quote:r.quote}:{})});
 }return{rooms};
 }catch{return{error:'Reload the group booking form and check its rooms.'};}
}
export function groupStayError(arrival:string,departure:string){return !validDay(arrival)||!validDay(departure)||stayNights(arrival,departure)<1||stayNights(arrival,departure)>365?'Choose valid stay dates for 1–365 nights.':undefined;}

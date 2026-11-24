"use server";
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { validEmail } from '@/lib/auth';
import { validDay,validId,stayNights,type Quote } from '@/lib/reservations';
export type BookingState={error?:string;input?:Record<string,string>};
export type QuoteState={error?:string;quote?:Quote;key?:string;input?:Record<string,string>};
export type OperationState={error?:string;success?:string};
export type BulkState={error?:string;results?:{id:string;success:boolean;error?:string}[]};
const text=(fd:FormData,key:string)=>String(fd.get(key)??'').trim();
const inputSnapshot=(fd:FormData)=>Object.fromEntries(['guest_id','name','email','phone','check_in','check_out','adults','children','type_id','rate_id','unit_id','notes','source'].filter(k=>fd.has(k)).map(k=>[k,text(fd,k).slice(0,2000)]));
const bookingError=(error:string,fd:FormData):BookingState=>({error,input:inputSnapshot(fd)});
function args(fd:FormData){return {p_property:text(fd,'pid'),p_type:text(fd,'type_id'),p_in:text(fd,'check_in'),p_out:text(fd,'check_out'),p_adults:Number(fd.get('adults')),p_children:Number(fd.get('children')),p_rate:text(fd,'rate_id')||null};}
function validation(a:ReturnType<typeof args>){
 if(!validId(a.p_property)||!validId(a.p_type)||(a.p_rate&&!validId(a.p_rate)))return 'Choose a hotel, room type, and valid rate plan.';
 if(!validDay(a.p_in)||!validDay(a.p_out)||stayNights(a.p_in,a.p_out)<1||stayNights(a.p_in,a.p_out)>365)return 'Choose valid dates for a stay of 1–365 nights.';
 if(!Number.isInteger(a.p_adults)||a.p_adults<1||!Number.isInteger(a.p_children)||a.p_children<0)return 'Enter a valid number of adults and children.';
}
function message(error:{code?:string;message:string}){
 if(error.code==='42501')return 'Your account does not have permission for this action.';
 if(error.code==='23P01')return 'That room was just booked or blocked. Check availability and choose another room.';
 if(error.code==='40001')return 'This reservation changed in another session. Refresh before continuing.';
 if(['22023','P0002'].includes(error.code??''))return error.message;
 return 'We couldn’t complete this action. Refresh and try again.';
}
export async function checkAvailability(_:QuoteState,fd:FormData):Promise<QuoteState>{
 const a=args(fd),error=validation(a);if(error)return {error,input:inputSnapshot(fd)};
 const exclude=text(fd,'exclude');if(exclude&&!validId(exclude))return {error:'Reservation not found.',input:inputSnapshot(fd)};
 const db=await createClient();const {data,error:e}=await db.rpc('frontdesk_quote',{...a,p_exclude:exclude||null});
 if(e)return {error:message(e),input:inputSnapshot(fd)};
 return {input:inputSnapshot(fd),quote:data as Quote,key:JSON.stringify([a.p_type,a.p_in,a.p_out,a.p_adults,a.p_children,a.p_rate??''])};
}
export async function createBooking(_:BookingState,fd:FormData):Promise<BookingState>{
 const a=args(fd),error=validation(a);if(error)return bookingError(error,fd);
 const name=text(fd,'name'),phone=text(fd,'phone'),email=text(fd,'email'),request=text(fd,'request'),unit=text(fd,'unit_id');
 if(!text(fd,'guest_id')&&(name.length<2||name.length>120||phone.length>40||(email&&!validEmail(email))))return bookingError('Check the guest name, phone, and email.',fd);
 if(!validId(request)||(text(fd,'guest_id')&&!validId(text(fd,'guest_id')))||(unit&&!validId(unit)))return bookingError('Reload this booking form and try again.',fd);
 if(!text(fd,'quote')||!Number.isFinite(Number(fd.get('quote'))))return bookingError('Check availability before confirming the booking.',fd);
 const db=await createClient(),common={...a,p_contact_permission:fd.get('contact_permission')==='on',p_contact_evidence:text(fd,'contact_evidence'),p_currency:text(fd,'currency'),p_request:request,p_unit:unit||null,p_notes:text(fd,'notes'),p_source:text(fd,'source'),p_quote:Number(fd.get('quote'))};
 if(text(fd,'booking_mode')==='walk_in'){
  const {p_source,...walkIn}=common;const{data,error:e}=await db.rpc('frontdesk_walk_in',{...walkIn,p_guest:text(fd,'guest_id')||null,p_guest_name:name,p_phone:phone,p_email:email});
  if(e)return bookingError(message(e),fd);
  revalidatePath('/dashboard');revalidatePath(`/p/${a.p_property}/reservations`,'layout');
  redirect(`/p/${a.p_property}/reservations/${data.id}?notice=${data.status==='checked_in'?'walk_in':'walk_in_pending'}`);
 }
 const {data,error:e}=text(fd,'guest_id')?await db.rpc('frontdesk_create_existing_guest',{...common,p_guest:text(fd,'guest_id')}):await db.rpc('frontdesk_create_whatsapp',{...common,p_guest_name:name,p_phone:phone,p_email:email});
 if(e)return bookingError(message(e),fd);
 revalidatePath('/dashboard');revalidatePath(`/p/${a.p_property}/reservations`);
 redirect(`/p/${a.p_property}/reservations/${data}?notice=created`);
}
export async function editGuestDetails(_:OperationState,fd:FormData):Promise<OperationState>{
 const pid=text(fd,'pid'),guest=text(fd,'guest'),version=Number(fd.get('profile_version')),name=text(fd,'name'),phone=text(fd,'phone'),email=text(fd,'email'),reason=text(fd,'reason');
 if(!validId(pid)||!validId(guest)||!Number.isInteger(version)||version<1)return{error:'Refresh the guest profile before saving.'};
 if(name.length<2||name.length>120||phone.length>40||(email&&!validEmail(email))||reason.length<3||reason.length>500)return{error:'Check the guest details and enter a change reason.'};
 const db=await createClient();const{error}=await db.rpc('frontdesk_edit_guest',{p_property:pid,p_guest:guest,p_version:version,p_name:name,p_phone:phone,p_email:email,p_reason:reason,p_confirm_phone:fd.get('confirm_phone')==='on'});
 if(error)return{error:message(error)};
 revalidatePath(`/p/${pid}/reservations`,'layout');revalidatePath(`/p/${pid}/inbox`);revalidatePath('/dashboard');
 return{success:'Guest details saved.'};
}
export async function bulkStayOperation(_:BulkState,fd:FormData):Promise<BulkState>{
 const pid=text(fd,'pid'),request=text(fd,'request'),operation=text(fd,'operation'),entries=fd.getAll('stay').map(String);
 if(!validId(pid)||!validId(request)||!['check_in','check_out'].includes(operation)||entries.length<1||entries.length>100||fd.get('confirmed')!=='on')return{error:'Select stays and confirm the batch before continuing.'};
 const items=entries.map(value=>{const[id,v]=value.split(':');return{id,version:Number(v)};});
 if(items.some(i=>!validId(i.id)||!Number.isInteger(i.version)||i.version<1)||new Set(items.map(i=>i.id)).size!==items.length)return{error:'Reload the selected stays before continuing.'};
 const db=await createClient();const{data,error}=await db.rpc('frontdesk_bulk_action',{p_property:pid,p_request:request,p_action:operation,p_items:items});
 if(error)return{error:message(error)};
 revalidatePath('/dashboard');revalidatePath(`/p/${pid}/reservations`,'layout');revalidatePath(`/p/${pid}/tasks`);revalidatePath(`/p/${pid}/billing`);
 return{results:data};
}
export async function editBooking(_:BookingState,fd:FormData):Promise<BookingState>{
 const a=args(fd),error=validation(a);if(error)return bookingError(error,fd);
 const id=text(fd,'id'),unit=text(fd,'unit_id');if(!validId(id)||(unit&&!validId(unit)))return bookingError('Reservation not found.',fd);
 const db=await createClient();const {data:existing,error:readError}=await db.from('reservations').select('id').eq('id',id).eq('property_id',a.p_property).maybeSingle();
 if(readError||!existing)return bookingError('Reservation not found in this hotel.',fd);
 const {p_property,...update}=a;
 const {error:e}=await db.rpc('frontdesk_update',{...update,p_id:id,p_version:Number(fd.get('version')),p_unit:unit||null,p_quote:Number(fd.get('quote'))});
 if(e)return bookingError(message(e),fd);
 revalidatePath('/dashboard');revalidatePath(`/p/${p_property}/reservations`,'layout');
 redirect(`/p/${p_property}/reservations/${id}?notice=updated`);
}
export async function reservationOperation(_:OperationState,fd:FormData):Promise<OperationState>{
 const id=text(fd,'id'),pid=text(fd,'pid'),operation=text(fd,'operation'),version=Number(fd.get('version'));
 if(!validId(id)||!validId(pid)||!Number.isInteger(version))return {error:'Reload this reservation before continuing.'};
 const db=await createClient();const {data,error:readError}=await db.from('reservations').select('id').eq('id',id).eq('property_id',pid).maybeSingle();
 if(readError||!data)return {error:'Reservation not found in this hotel.'};
 if(operation==='move'&&!validId(text(fd,'unit_id')))return {error:'Choose a destination room.'};
 const {error}=operation==='move'?await db.rpc('frontdesk_move',{p_id:id,p_version:version,p_unit:text(fd,'unit_id'),p_reason:text(fd,'reason')}):await db.rpc('frontdesk_action',{p_id:id,p_version:version,p_action:operation,p_reason:operation==='notes'?text(fd,'notes'):text(fd,'reason')});
 if(error)return {error:message(error)};
 revalidatePath('/dashboard');revalidatePath(`/p/${pid}/reservations`,'layout');
 redirect(`/p/${pid}/reservations/${id}?notice=${encodeURIComponent(operation)}`);
}

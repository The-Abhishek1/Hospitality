'use server';
import {redirect}from'next/navigation';
import {revalidatePath}from'next/cache';
import {createClient}from'@/lib/supabase/server';
import {validId}from'@/lib/reservations';
import {parseGroupRooms,groupStayError,groupQuoteKey,type GroupQuote}from'@/lib/group-bookings';
export type GroupState={error?:string};
export type GroupQuoteState=GroupState&{quote?:GroupQuote;key?:string};
const field=(fd:FormData,k:string)=>String(fd.get(k)??'').trim();
const friendly=(e:{code?:string;message:string})=>e.code==='42501'?'Your role cannot make this group booking.':e.code==='23P01'?'A room was just booked or blocked. Check availability again. None of this group was saved.':e.code==='40001'?'The quote or request changed. Refresh and review the group.':['22023','P0002'].includes(e.code??'')?e.message:'Couldn’t save the group. Refresh and try again.';
function setup(fd:FormData,reviewed:boolean){const pid=field(fd,'pid'),arrival=field(fd,'check_in'),departure=field(fd,'check_out'),mode=field(fd,'mode'),parsed=parseGroupRooms(field(fd,'rooms'),reviewed);return{pid,arrival,departure,mode,rooms:parsed.rooms,error:!validId(pid)||!['reservation','walk_in'].includes(mode)?'Choose a hotel and booking type.':groupStayError(arrival,departure)??parsed.error};}
export async function quoteGroup(_:GroupQuoteState,fd:FormData):Promise<GroupQuoteState>{
 const s=setup(fd,false);if(s.error||!s.rooms)return{error:s.error};const db=await createClient(),{data,error}=await db.rpc('frontdesk_group_quote',{p_property:s.pid,p_in:s.arrival,p_out:s.departure,p_mode:s.mode,p_items:s.rooms});
 return error?{error:friendly(error)}:{quote:data,key:groupQuoteKey(s.arrival,s.departure,s.mode,s.rooms)};
}
export async function bookGroup(_:GroupState,fd:FormData):Promise<GroupState>{
 const s=setup(fd,true),name=field(fd,'name'),request=field(fd,'request'),notes=field(fd,'notes');if(s.error||!s.rooms)return{error:s.error};
 if(!validId(request)||name.length<2||name.length>120||notes.length>1400||field(fd,'confirmed')!=='yes')return{error:'Enter a group name and confirm the reviewed rooms and guests.'};
 const db=await createClient(),{data,error}=await db.rpc('frontdesk_group_create',{p_property:s.pid,p_currency:field(fd,'currency'),p_request:request,p_name:name,p_mode:s.mode,p_in:s.arrival,p_out:s.departure,p_items:s.rooms,p_notes:notes});
 if(error)return{error:friendly(error)};
 revalidatePath('/dashboard');revalidatePath(`/p/${s.pid}/reservations`,'layout');revalidatePath(`/p/${s.pid}/inventory`);redirect(`/p/${s.pid}/reservations/groups/${data}?notice=created`);
}

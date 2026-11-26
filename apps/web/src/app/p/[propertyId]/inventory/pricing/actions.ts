'use server';
import{redirect}from'next/navigation';
import{revalidatePath}from'next/cache';
import{createClient}from'@/lib/supabase/server';
import{inventoryMoney}from'@/lib/inventory';
import{validId}from'@/lib/reservations';
import{pricingDays}from'@/lib/room-pricing';
export type PricingState={error?:string};
export async function saveRoomPrices(_:PricingState,fd:FormData):Promise<PricingState>{
 const value=(key:string)=>String(fd.get(key)??'').trim(),pid=value('pid'),type=value('type'),request=value('request'),version=Number(fd.get('version')),from=value('from'),to=value('to'),mask=Number(fd.get('weekdays')),reset=value('operation')==='reset',amount=inventoryMoney(value('amount')),label=value('label');
 if(!validId(pid)||!validId(type)||!validId(request)||!Number.isInteger(version)||version<0)return{error:'Refresh the calendar and choose a room type.'};
 if(!['set','reset'].includes(value('operation'))||!pricingDays(from,to,mask).length)return{error:'Choose a date range of up to 366 nights and at least one matching weekday.'};
 if(!reset&&!amount||label.length>120||fd.get('confirm')!=='on')return{error:'Check the nightly price and label, then confirm the dates before saving.'};
 const db=await createClient(),{data,error}=await db.rpc('room_pricing_save',{p_property:pid,p_request:request,p_version:version,p_type:type,p_from:from,p_to:to,p_weekdays:mask,p_amount:reset?null:amount,p_reset:reset,p_label:label});
 if(error)return{error:error.code==='42501'?'Inventory management access is required.':error.code==='40001'?'Room prices changed. Refresh the calendar and review your changes.':error.code==='22023'?error.message:'Could not save room prices. Refresh the calendar before trying again.'};
 revalidatePath(`/p/${pid}/inventory`,'layout');revalidatePath(`/p/${pid}/reservations`,'layout');
 redirect(`/p/${pid}/inventory/pricing?${new URLSearchParams({start:from,type,saved:String(data.nights),operation:reset?'reset':'set'})}`);
}

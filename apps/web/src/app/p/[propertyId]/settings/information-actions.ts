'use server';
import{revalidatePath}from'next/cache';import{createClient}from'@/lib/supabase/server';import{hotelLinkChoices,type HotelLinks}from'@/lib/hotel-message-resources';import{hotelInformationErrors,type HotelInformationErrors}from'@/lib/hotel-information-validation';
export type HotelInformationState={error?:string;success?:string;version?:number;fieldErrors?:HotelInformationErrors;values?:HotelLinks&{reason:string}};
export async function saveHotelInformation(_:HotelInformationState,fd:FormData):Promise<HotelInformationState>{
 const pid=String(fd.get('pid')??''),version=Number(fd.get('version')),reason=String(fd.get('reason')??'').trim(),links=Object.fromEntries(hotelLinkChoices.map(i=>[i.key,String(fd.get(i.key)??'').trim()]))as HotelLinks;
 if(!/^[a-f0-9-]{36}$/.test(pid)||!Number.isInteger(version)||version<0)return{error:'Reload this hotel’s information form.'};
 const fieldErrors=hotelInformationErrors(links,reason);if(Object.keys(fieldErrors).length)return{error:'Check the highlighted fields below.',fieldErrors,values:{...links,reason}};
 const db=await createClient(),{data,error}=await db.rpc('save_hotel_message_links',{p_property:pid,p_version:version,p_links:links,p_reason:reason});
 if(error)return{error:['22023','40001','42501'].includes(error.code)?error.message:'Could not save hotel information. Try again.'};
 revalidatePath(`/p/${pid}/settings`);revalidatePath(`/p/${pid}/automations`);
 return{success:'Hotel links saved. Existing template buttons retain their saved URLs.',version:data};
}

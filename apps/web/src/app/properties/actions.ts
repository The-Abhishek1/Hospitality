"use server";
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { createClient } from '@/lib/supabase/server';
import { validEmail } from '@/lib/auth';
export type PropertyState = { error?: string };
const field=(fd:FormData,k:string)=>String(fd.get(k)??'').trim();
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
function read(fd:FormData) {
  return {name:field(fd,'name'),property_type:field(fd,'property_type'),timezone:field(fd,'timezone'),currency:field(fd,'currency').toUpperCase(),address:field(fd,'address'),city:field(fd,'city'),country_code:field(fd,'country_code').toUpperCase(),contact_email:field(fd,'contact_email').toLowerCase(),contact_phone:field(fd,'contact_phone')};
}
function validate(v:ReturnType<typeof read>) {
  if(v.name.length<2||v.name.length>120)return 'Property name must be 2–120 characters.';
  if(!['hotel','resort','hostel','homestay'].includes(v.property_type))return 'Choose a property type.';
  try{new Intl.DateTimeFormat('en',{timeZone:v.timezone}).format();}catch{return 'Choose a valid IANA timezone.';}
  if(!Intl.supportedValuesOf('currency').includes(v.currency))return 'Choose a supported currency.';
  if(!/^[A-Z]{2}$/.test(v.country_code))return 'Enter a two-letter country code, such as IN.';
  if(v.contact_email&&!validEmail(v.contact_email))return 'Enter a valid contact email.';
  if(v.address.length>1000||v.city.length>120||v.contact_phone.length>40)return 'Check the address, city and phone lengths.';
}
function friendly(code?:string){return code==='53400'?'Your plan’s property limit has been reached. Contact your platform administrator to change your plan.':code==='42501'?'Only the business owner or an admin can manage properties.':code==='22023'?'These settings cannot be changed. Currency is locked once bookings or orders exist.':'Couldn’t save the property. Check the details and try again.';}
export async function createProperty(_:PropertyState,fd:FormData):Promise<PropertyState>{
 const v=read(fd),error=validate(v);if(error)return {error};
 const tenant=field(fd,'tenant'),request=field(fd,'request');
 if(!uuid(tenant)||!uuid(request))return {error:'Reload this page and try again.'};
 const db=await createClient();
 const {data,error:e}=await db.rpc('create_property',{p_tenant:tenant,p_request:request,p_name:v.name,p_type:v.property_type,p_timezone:v.timezone,p_currency:v.currency,p_details:{address:v.address,city:v.city,country_code:v.country_code,contact_email:v.contact_email,contact_phone:v.contact_phone}});
 if(e)return {error:friendly(e.code)};
 revalidatePath('/dashboard');revalidatePath('/properties');
 redirect(`/p/${data}/settings?created=1`);
}
export async function updateProperty(_:PropertyState,fd:FormData):Promise<PropertyState>{
 const v=read(fd),error=validate(v);if(error)return {error};
 const id=field(fd,'property');if(!uuid(id))return {error:'Property not found.'};
 const db=await createClient();
 const {data,error:e}=await db.from('properties').update(v).eq('id',id).select('id').single();
 if(e||!data)return {error:friendly(e?.code)};
 revalidatePath('/dashboard');revalidatePath('/properties');revalidatePath(`/p/${id}`,'layout');
 redirect(`/p/${id}/settings?saved=1`);
}

"use server";
import{redirect}from 'next/navigation';import{revalidatePath}from 'next/cache';import{createClient}from '@/lib/supabase/server';import{validId}from '@/lib/reservations';import{parseChecklist}from '@/lib/tasks';import{validLocalTime,boundedWhole}from '@/lib/property-settings';
export type SettingsState={error?:string;fields?:Record<string,string>};
const field=(fd:FormData,k:string)=>String(fd.get(k)??'').trim();
const friendly=(e:{code?:string;message:string})=>e.code==='42501'?'Only business owners and administrators manage property settings.':e.code==='40001'?'This hotel’s settings changed. Refresh and review the current configuration.':['22023','P0002'].includes(e.code??'')?e.message:'Couldn’t save these settings. Check the values and try again.';
export async function saveSettings(_:SettingsState,fd:FormData):Promise<SettingsState>{
 const pid=field(fd,'pid'),request=field(fd,'request'),section=field(fd,'section'),version=Number(field(fd,'version')),settingsVersion=Number(field(fd,'settings_version'));
 const fields=Object.fromEntries(['name','property_type','address','city','country_code','contact_email','contact_phone','timezone','currency','check_in_time','check_out_time','arrival_instructions','stay_information','booking_nights','booking_adults','default_rate_plan_id','cleaning_target_minutes','cleaning_priority','cleaning_checklist','reason'].map(k=>[k,field(fd,k)])),fail=(error:string)=>({error,fields});
 if(!validId(pid)||!validId(request)||!Number.isInteger(version)||version<1||!Number.isInteger(settingsVersion)||settingsVersion<1||!['identity','localization','guest','operations'].includes(section))return fail('Reload this property settings form.');
 if(fields.reason.length<3||fields.reason.length>500)return fail('Give a change reason of 3–500 characters.');if(field(fd,'confirm')!=='yes')return fail('Review and confirm this configuration change.');
 const details:Record<string,unknown>={reason:fields.reason};
 if(section==='identity'){
 if(fields.name.length<2||fields.name.length>120||!['hotel','resort','hostel','homestay'].includes(fields.property_type)||fields.address.length>1000||fields.city.length>120||fields.contact_phone.length>40||fields.contact_email.length>254||!/^[A-Za-z]{2}$/.test(fields.country_code))return fail('Check the property name, type, address and two-letter country code.');
 if(fields.contact_email&&!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(fields.contact_email))return fail('Enter a valid contact email.');
 Object.assign(details,{name:fields.name,property_type:fields.property_type,address:fields.address,city:fields.city,country_code:fields.country_code.toUpperCase(),contact_email:fields.contact_email.toLowerCase(),contact_phone:fields.contact_phone});
 }else if(section==='localization'){
 try{new Intl.DateTimeFormat('en',{timeZone:fields.timezone}).format();}catch{return fail('Choose a valid IANA timezone.');}if(!Intl.supportedValuesOf('currency').includes(fields.currency))return fail('Choose a supported currency.');Object.assign(details,{timezone:fields.timezone,currency:fields.currency,confirm_timezone:field(fd,'confirm_timezone')==='yes',confirm_currency:field(fd,'confirm_currency')==='yes'});
 }else if(section==='guest'){
 if(!validLocalTime(fields.check_in_time)||!validLocalTime(fields.check_out_time)||fields.arrival_instructions.length>2000||fields.stay_information.length>2000)return fail('Choose valid 24-hour times and keep guest information under 2000 characters per field.');Object.assign(details,{check_in_time:fields.check_in_time,check_out_time:fields.check_out_time,arrival_instructions:fields.arrival_instructions,stay_information:fields.stay_information});
 }else{
 const checklist=parseChecklist(fields.cleaning_checklist);if(!boundedWhole(fields.booking_nights,1,30)||!boundedWhole(fields.booking_adults,1,10)||fields.default_rate_plan_id&&!validId(fields.default_rate_plan_id)||fields.cleaning_target_minutes&&!boundedWhole(fields.cleaning_target_minutes,1,10080)||!['low','normal','high','urgent'].includes(fields.cleaning_priority)||!checklist)return fail('Check booking defaults, cleaning target and up to 20 checklist lines (160 characters each).');Object.assign(details,{booking_nights:fields.booking_nights,booking_adults:fields.booking_adults,default_rate_plan_id:fields.default_rate_plan_id,cleaning_target_minutes:fields.cleaning_target_minutes,cleaning_priority:fields.cleaning_priority,cleaning_checklist:checklist});
 }
 const db=await createClient(),{error}=await db.rpc('property_settings_save',{p_property:pid,p_version:version,p_settings_version:settingsVersion,p_request:request,p_section:section,p_details:details});if(error)return fail(friendly(error));
 revalidatePath('/dashboard');revalidatePath('/properties');revalidatePath(`/p/${pid}`,'layout');redirect(`/p/${pid}/settings?tab=${section}&notice=saved`);
}

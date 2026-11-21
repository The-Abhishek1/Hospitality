"use server";
import{revalidatePath}from 'next/cache';import{redirect}from 'next/navigation';import{createClient}from '@/lib/supabase/server';import{validId}from '@/lib/reservations';
export type PlatformState={error?:string};
export async function managePlatform(_:PlatformState,fd:FormData):Promise<PlatformState>{
 const value=(key:string)=>String(fd.get(key)??'').trim(),action=value('action'),tenant=value('tenant'),version=value('version'),request=value('request');
 if(!validId(request)||!['plan','status','add_hotel','onboard'].includes(action)||action!=='onboard'&&(!validId(tenant)||!/^\d+$/.test(version)||Number(version)<1||Number(version)>2147483647))return{error:'This administration form expired. Refresh and try again.'};
 const details:Record<string,string>={reason:value('reason')};
 const keys=action==='plan'?['plan','confirmation']:action==='status'?['status','confirmation']:['name','property_type','timezone','currency','city','country_code',...(action==='onboard'?['business_name','slug','owner_email','plan']:[])];for(const key of keys)details[key]=value(key);
 if(action==='onboard'||action==='add_hotel'){details.country_code=details.country_code.toUpperCase();if(!Intl.supportedValuesOf('currency').includes(details.currency))return{error:'Choose a supported hotel currency.'};}
 const db=await createClient(),{data,error}=await db.rpc('platform_manage',{p_tenant:action==='onboard'?null:tenant,p_version:action==='onboard'?null:Number(version),p_request:request,p_action:action,p_details:details});
 if(error)return{error:error.code==='23505'?'That business slug is already in use. Choose a different slug.':['22023','53400','40001','P0002','42501'].includes(error.code)?error.message:'The change could not be saved. Refresh and try again.'};
 revalidatePath('/admin','layout');revalidatePath('/dashboard');revalidatePath('/properties');
 redirect(`/admin/businesses/${data.tenant_id}?notice=${action}`);
}

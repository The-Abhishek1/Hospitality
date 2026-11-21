"use server";
import {redirect} from 'next/navigation';
import {revalidatePath} from 'next/cache';
import {createClient} from '@/lib/supabase/server';
import {validId} from '@/lib/reservations';
import {validTarget,requestPriorities,type RequestSetup,type StayOption} from '@/lib/service-desk';
export type ServiceState={error?:string;fields?:Record<string,string>;selected?:StayOption|null};
export type StaySearchState={error?:string;data?:RequestSetup;query?:string};
const field=(fd:FormData,k:string)=>String(fd.get(k)??'').trim();
const snapshot=(fd:FormData)=>Object.fromEntries(['reservation_id','catalog_id','title','notes','priority','target_minutes','operation','reason','body','rating','comment','deadline','assignee','kind','name','category','description','department'].filter(k=>fd.has(k)).map(k=>[k,field(fd,k).slice(0,2000)]));
const friendly=(e:{code?:string;message:string})=>e.code==='42501'?'Your role does not allow this action. Linked tasks must be updated by their assignee or a task manager.':e.code==='40001'?'This request or service changed. Refresh and review the current details.':e.code==='23505'?'This service, feedback, or action is already recorded. Refresh before trying again.':['22023','P0002'].includes(e.code??'')?e.message:'Couldn’t save these details. Refresh and try again.';
export async function findRequestStays(_:StaySearchState,fd:FormData):Promise<StaySearchState>{
 const pid=field(fd,'pid'),selected=field(fd,'selected'),q=field(fd,'query').slice(0,100);if(!validId(pid)||(selected&&!validId(selected)))return{error:'Hotel or stay not found.'};
 const db=await createClient();const{data,error}=await db.rpc('service_request_setup',{p_property:pid,p_query:q,p_reservation:selected||null});if(error)return{error:friendly(error),query:q};return{data:data as RequestSetup,query:q};
}
export async function createRequest(_:ServiceState,fd:FormData):Promise<ServiceState>{
 const pid=field(fd,'pid'),request=field(fd,'request'),stay=field(fd,'reservation_id'),service=field(fd,'catalog_id'),fields=snapshot(fd);
 const db=await createClient();
 const fail=async(error:string):Promise<ServiceState>=>{let selected:StayOption|null=null;if(validId(pid)&&validId(stay)){const{data}=await db.rpc('service_request_setup',{p_property:pid,p_reservation:stay,p_query:''});selected=data?.selected??null;}return{error,fields,selected};};
 if(!validId(pid)||!validId(request)||!validId(stay)||(service&&!validId(service)))return fail('Choose an active guest stay and service.');
 if(!service&&field(fd,'title').length<2)return fail('Give this custom request a title (at least 2 characters).');
 if(field(fd,'title').length>200||field(fd,'notes').length>2000)return fail('Keep the title under 200 characters and details under 2000.');
 if(!requestPriorities.includes(field(fd,'priority') as typeof requestPriorities[number])||!validTarget(field(fd,'target_minutes')))return fail('Choose a priority and a response target of 1–10080 minutes, or leave the target blank.');
 const details={reservation_id:stay,catalog_id:service,title:field(fd,'title'),notes:field(fd,'notes'),priority:field(fd,'priority'),target_minutes:field(fd,'target_minutes')};
 const{data,error}=await db.rpc('service_desk_create',{p_property:pid,p_request:request,p_details:details});if(error)return fail(friendly(error));
 revalidatePath('/dashboard');revalidatePath(`/p/${pid}/requests`,'layout');revalidatePath(`/p/${pid}/tasks`,'layout');
 redirect(`/p/${pid}/requests/${data}?notice=created`);
}
export async function requestOperation(_:ServiceState,fd:FormData):Promise<ServiceState>{
 const pid=field(fd,'pid'),id=field(fd,'id'),request=field(fd,'request'),op=field(fd,'operation'),fields=snapshot(fd),version=Number(fd.get('version'));
 const fail=(error:string):ServiceState=>({error,fields});
 if(!validId(pid)||!validId(id)||!validId(request)||!Number.isInteger(version))return fail('Reload this request and try again.');
 if(!['start','complete','cancel','triage','assign','claim','attach_task','comment','feedback'].includes(op))return fail('Choose a valid request action.');
 if(field(fd,'confirm')!=='yes')return fail('Confirm this action before saving.');
 const details:Record<string,string>={};
 if(op==='cancel'){if(field(fd,'reason').length<3||field(fd,'reason').length>500)return fail('Enter a cancellation reason (3–500 characters).');details.reason=field(fd,'reason');}
 if(op==='triage'){if(!requestPriorities.includes(field(fd,'priority') as typeof requestPriorities[number]))return fail('Choose a valid priority.');details.priority=field(fd,'priority');details.deadline=field(fd,'deadline');if(details.deadline==='set'){if(!field(fd,'target_minutes')||!validTarget(field(fd,'target_minutes')))return fail('Enter a response target of 1–10080 minutes.');details.target_minutes=field(fd,'target_minutes');}}
 if(op==='assign'){if(field(fd,'assignee')&&!validId(field(fd,'assignee')))return fail('Choose an eligible teammate.');details.assignee=field(fd,'assignee');}
 if(op==='attach_task'){if(!['housekeeping','maintenance','general'].includes(field(fd,'kind')))return fail('Choose a task kind.');details.kind=field(fd,'kind');}
 if(op==='comment'){if(!field(fd,'body')||field(fd,'body').length>2000)return fail('Write an internal comment of 1–2000 characters.');details.body=field(fd,'body');}
 if(op==='feedback'){if(!/^[1-5]$/.test(field(fd,'rating'))||field(fd,'comment').length>1000)return fail('Choose 1–5 stars and a comment up to 1000 characters.');details.rating=field(fd,'rating');details.comment=field(fd,'comment');}
 const db=await createClient();const{error}=await db.rpc('service_desk_action',{p_property:pid,p_id:id,p_version:version,p_request:request,p_action:op,p_details:details});if(error)return fail(friendly(error));
 revalidatePath('/dashboard');revalidatePath(`/p/${pid}/requests`,'layout');revalidatePath(`/p/${pid}/tasks`,'layout');
 redirect(`/p/${pid}/requests/${id}?notice=${op}`);
}
export async function saveService(_:ServiceState,fd:FormData):Promise<ServiceState>{
 const pid=field(fd,'pid'),request=field(fd,'request'),id=field(fd,'catalog_id'),fields={...snapshot(fd),active:field(fd,'active')==='yes'?'yes':'no'};const fail=(error:string):ServiceState=>({error,fields});
 if(!validId(pid)||!validId(request)||(id&&!validId(id)))return fail('Reload this service form and try again.');
 if(field(fd,'name').length<2||field(fd,'name').length>120||field(fd,'category').length<2||field(fd,'category').length>80||field(fd,'description').length>500)return fail('Check the name, category, and description lengths.');
 if(!requestPriorities.includes(field(fd,'priority') as typeof requestPriorities[number])||!validTarget(field(fd,'target_minutes')))return fail('Choose a valid priority and target of 1–10080 minutes, or leave the target blank.');
 const assignee=field(fd,'assignee'),department=field(fd,'department');if((assignee&&!validId(assignee))||(department&&!validId(department)))return fail('Choose a valid department and default assignee.');
 const db=await createClient();const{data,error}=await db.rpc('service_catalog_save',{p_property:pid,p_request:request,p_catalog:id||null,p_version:id?Number(fd.get('version')):null,p_details:{name:field(fd,'name'),category:field(fd,'category'),description:field(fd,'description'),priority:field(fd,'priority'),target_minutes:field(fd,'target_minutes'),kind:field(fd,'kind'),assignee,department,active:field(fd,'active')==='yes'}});
 if(error)return fail(friendly(error));revalidatePath(`/p/${pid}/requests`,'layout');
 redirect(`/p/${pid}/requests/catalog?notice=saved&service=${data}`);
}

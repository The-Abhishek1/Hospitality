'use server';
import {redirect} from 'next/navigation';
import {revalidatePath} from 'next/cache';
import {createClient} from '@/lib/supabase/server';
import {campaignFilters,type CampaignAudience} from '@/lib/campaigns';
export type CampaignResult={error?:string;message?:string};
export async function loadAudience(pid:string,filters:unknown,page:number):Promise<{data?:CampaignAudience;error?:string}>{
 const db=await createClient(),{data,error}=await db.rpc('campaign_audience',{p_property:pid,p_filters:campaignFilters(filters),p_page:page});
 return error?{error:'Could not load this audience. Check dates and hotel access.'}:{data:data as CampaignAudience};
}
export async function saveCampaign(_:CampaignResult,fd:FormData):Promise<CampaignResult>{
 let filters:unknown,selected:unknown;
 try{filters=JSON.parse(String(fd.get('filters')));selected=JSON.parse(String(fd.get('selected')));}catch{return{error:'Refresh the audience preview and try again.'};}
 const pid=String(fd.get('pid')),db=await createClient();
 const{data,error}=await db.rpc('save_whatsapp_campaign',{p_property:pid,p_request:String(fd.get('request')),p_id:null,p_version:0,p_data:{name:String(fd.get('name')||'').trim(),body:String(fd.get('body')||''),filters:campaignFilters(filters),selection_mode:String(fd.get('mode')),selected_guests:selected,template_id:String(fd.get('template')||'')}});
 if(error)return{error:error.message};
 revalidatePath(`/p/${pid}/campaigns`);redirect(`/p/${pid}/campaigns/${data}`);
}
export async function campaignAction(_:CampaignResult,fd:FormData):Promise<CampaignResult>{
 const pid=String(fd.get('pid')),id=String(fd.get('campaign')),db=await createClient(),action=String(fd.get('action'));
 if(!['launch','cancel'].includes(action))return{error:'Invalid campaign action.'};
 if(action==='launch'&&fd.get('confirmed')!=='on')return{error:'Confirm the message and eligible audience before scheduling.'};
 const{data,error}=action==='launch'?await db.rpc('launch_whatsapp_campaign',{p_property:pid,p_id:id,p_version:Number(fd.get('version')),p_local_time:fd.get('timing')==='later'?String(fd.get('local_time')||''):null}):await db.rpc('cancel_whatsapp_campaign',{p_property:pid,p_id:id,p_version:Number(fd.get('version'))});
 if(error)return{error:error.code==='40001'?'This campaign changed. Refresh before continuing.':error.message};
 revalidatePath(`/p/${pid}/campaigns`);revalidatePath(`/p/${pid}/campaigns/${id}`);
 return{message:action==='launch'?`Scheduled for ${data} eligible recipients. Delivery requires the enabled campaign worker.`:'Campaign cancelled. In-flight or accepted messages cannot be recalled.'};
}
export async function permissionAction(_:CampaignResult,fd:FormData):Promise<CampaignResult>{
 const pid=String(fd.get('pid')),db=await createClient();
 const{error}=await db.rpc('record_marketing_permission',{p_property:pid,p_guest:String(fd.get('guest')),p_status:String(fd.get('status')),p_evidence:String(fd.get('evidence')||'').trim()});
 if(error)return{error:error.message};revalidatePath(`/p/${pid}/campaigns`);return{message:'Permission record saved. Refresh the audience preview to see current eligibility.'};
}
export async function updateCampaign(_:CampaignResult,fd:FormData):Promise<CampaignResult>{
 const pid=String(fd.get('pid')),id=String(fd.get('campaign')),db=await createClient();
 const{data:c,error:readError}=await db.from('whatsapp_campaigns').select('name,filters,selected_guests,selection_mode').eq('property_id',pid).eq('id',id).single();
 if(readError||!c)return{error:'Campaign unavailable.'};
 const{error}=await db.rpc('save_whatsapp_campaign',{p_property:pid,p_request:String(fd.get('request')),p_id:id,p_version:Number(fd.get('version')),p_data:{...c,body:String(fd.get('body')||''),template_id:String(fd.get('template')||'')}});
 if(error)return{error:error.message};revalidatePath(`/p/${pid}/campaigns/${id}`);return{message:'Draft message saved. Review before scheduling.'};
}

'use server';
import{anon}from'@/lib/supabase';import{validId,validToken}from'@/lib/portal';
export type GuestConsentStatus={updates:string;marketing:string;verified_at:string|null;phone_hint:string;can_request:boolean;pending_until:string|null};
export type ConsentState={error?:string;success?:string;url?:string;created_at?:string;expires_at?:string;submission?:string;marketing?:boolean};
export async function getGuestConsent(token:string):Promise<GuestConsentStatus|null>{if(!validToken(token))return null;const{data,error}=await anon().rpc('portal_command',{p_token:token,p_request:null,p_action:'consent_status',p_payload:{}});return error?null:data;}
export async function saveGuestConsent(_:ConsentState,fd:FormData):Promise<ConsentState>{
 const token=String(fd.get('token')??''),request=String(fd.get('request')??''),purpose=String(fd.get('purpose')??''),revoke=fd.get('operation')==='revoke',cancel=fd.get('operation')==='cancel';
 if(!validToken(token)||!validId(request))return{error:'Refresh your personal stay page.'};
 if(!revoke&&!cancel&&fd.get('updates')!=='on')return{error:'Choose whether to receive stay updates before continuing.'};
 if(revoke&&!['updates','marketing','both'].includes(purpose))return{error:'Choose which messages to stop.'};
 const{data,error}=await anon().rpc('portal_command',{p_token:token,p_request:request,p_action:cancel?'consent_cancel':revoke?'consent_revoke':'consent_start',p_payload:cancel?{}:revoke?{purpose}:{updates:true,marketing:fd.get('marketing')==='on'}});
 if(error)return{error:['22023','54000'].includes(error.code)?error.message:'Your stay link is unavailable. Refresh or contact reception.'};
 if(cancel)return{success:'Verification cancelled. You can change your choices and generate a new link.',submission:request};
 if(revoke)return{success:'Your messaging preference has been withdrawn.',submission:request};
 if(data.already_requested)return{success:'Verification was already requested. Generate a fresh link if you need another one.',submission:request};
 if(!/^[1-9][0-9]{7,14}$/.test(data.phone)||typeof data.message!=='string')return{error:'The hotel’s WhatsApp details are unavailable.'};
 return{url:`https://wa.me/${data.phone}?${new URLSearchParams({text:data.message})}`,created_at:data.created_at,expires_at:data.expires_at,marketing:fd.get('marketing')==='on',submission:request};
}

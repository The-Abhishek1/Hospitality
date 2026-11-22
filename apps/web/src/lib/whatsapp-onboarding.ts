import {templateProviderError} from './automation-flow';
import {createClient as backendClient}from'@supabase/supabase-js';
import{encryptToken,decryptToken}from'../../../../packages/whatsapp-security/index.mjs';
export const graphVersion=process.env.WHATSAPP_GRAPH_VERSION||'v27.0';
export function onboardingReady(){return Boolean(process.env.WHATSAPP_APP_ID&&process.env.WHATSAPP_APP_SECRET&&process.env.WHATSAPP_CONFIG_ID&&/^[a-f0-9]{64}$/i.test(process.env.WHATSAPP_ENCRYPTION_KEY??'')&&process.env.SUPABASE_SERVICE_ROLE_KEY&&/^https:\/\/[^/]+$/.test(process.env.WHATSAPP_ONBOARDING_ORIGIN??''));}
export function backend(){return backendClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.SUPABASE_SERVICE_ROLE_KEY!,{auth:{persistSession:false,autoRefreshToken:false}});}
export class SetupError extends Error{}
export async function meta(path:string,token:string,method='GET',body?:Record<string,string>,context?:'template'){
 const response=await fetch(`https://graph.facebook.com/${graphVersion}/${path}`,{method,headers:{Authorization:`Bearer ${token}`,...(body?{'Content-Type':'application/x-www-form-urlencoded'}:{})},body:body?new URLSearchParams(body):undefined,signal:AbortSignal.timeout(20000),cache:'no-store'});
 const data=await response.json();if(!response.ok||data.error)throw new SetupError(context==='template'?templateProviderError(data.error??{},response.status,token):`Meta rejected this step (code ${data.error?.code??response.status}). Check permissions, number registration and account status in Meta, then reconnect.`);
 return data;
}
export async function exchangeCode(code:string){
 const query=new URLSearchParams({client_id:process.env.WHATSAPP_APP_ID!,client_secret:process.env.WHATSAPP_APP_SECRET!,code});
 const data=await meta(`oauth/access_token?${query}`,`${process.env.WHATSAPP_APP_ID}|${process.env.WHATSAPP_APP_SECRET}`);
 if(!data.access_token)throw new SetupError('Meta did not return an authorization token. Start again.');
 return data.access_token as string;
}
export async function verifyAuthorization(token:string){
 const d=await meta(`debug_token?input_token=${encodeURIComponent(token)}`,`${process.env.WHATSAPP_APP_ID}|${process.env.WHATSAPP_APP_SECRET}`),a=d.data;
 if(!a?.is_valid||a.app_id!==process.env.WHATSAPP_APP_ID||!['whatsapp_business_management','whatsapp_business_messaging'].every(scope=>a.scopes?.includes(scope)))throw new SetupError('Meta authorization is missing required WhatsApp permissions. Start again and grant messaging and account-management access.');
}
export async function verifySender(token:string,waba:string,phone:string){
 // IDs returned by the popup are untrusted: confirm ownership with the exchanged token.
 let path=`${waba}/phone_numbers?fields=id,display_phone_number,verified_name,code_verification_status&limit=100`;
 for(let page=0;page<20;page++){
  const d=await meta(path,token),sender=d.data?.find((p:{id:string})=>p.id===phone);
  if(sender)return sender as{id:string;display_phone_number:string;verified_name:string;code_verification_status:string};
  if(!d.paging?.next||!d.paging?.cursors?.after)break;
  path=`${waba}/phone_numbers?fields=id,display_phone_number,verified_name,code_verification_status&limit=100&after=${encodeURIComponent(d.paging.cursors.after)}`;
 }
 throw new SetupError('The selected number does not belong to the authorized WhatsApp account.');
}
export function seal(token:string,pid:string){return encryptToken(token,`managed:${pid}`,process.env.WHATSAPP_ENCRYPTION_KEY);}
export async function savedToken(reference:string){const {data,error}=await backend().rpc('whatsapp_delivery_credential',{p_reference:reference});if(error||!data)throw new SetupError('Reconnect this number to authorize secure credential storage.');return decryptToken(data,reference,process.env.WHATSAPP_ENCRYPTION_KEY);}

import {NextRequest,NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {backend,savedToken,graphVersion,meta,SetupError} from '@/lib/whatsapp-onboarding';
import {createTemplatePayload} from '@/lib/automation-flow';
import {fetchTemplates} from '../../../../../../../../packages/whatsapp-security/templates.mjs';
export const runtime='nodejs';export const maxDuration=180;
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 const response=(b:object,s=200)=>NextResponse.json(b,{status:s,headers:{'Cache-Control':'no-store'}});
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return response({error:'Open the configured hotel app address.'},403);
 const{propertyId:pid}=await params,db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return response({error:'Sign in again.'},401);
 const {data,error}=await db.rpc('whatsapp_setup_context',{p_property:pid});if(error||data?.connection?.status!=='active')return response({error:'Connect this hotel’s WhatsApp number first. Hotel administrator access is required.'},403);
 let input:{action?:string;event?:string;name?:string;language?:string;body?:string}={};
 try{const raw=await req.text();if(raw.length>20000)return response({error:'Template submission is too large.'},413);input=raw?JSON.parse(raw):{};if(!input||Array.isArray(input)||typeof input!=='object')throw Error();}catch{return response({error:'Check the template form and try again.'},400);}
 if(input.action&&!['sync','submit'].includes(input.action))return response({error:'Unknown template action.'},400);
 let payload:ReturnType<typeof createTemplatePayload>|undefined;
 if(input.action==='submit'){
  try{if(['event','name','language','body'].some(k=>typeof input[k as keyof typeof input]!=='string'))throw Error('Complete the template form.');payload=createTemplatePayload({event:input.event!,name:input.name!,language:input.language!,body:input.body!});}catch(e){return response({error:e instanceof Error?e.message:'Check your template details.'},400);}
 }
 let accepted=false;
 try{
  const token=await savedToken(`managed:${pid}`);
  if(payload){
   const current=await meta(`${data.connection.waba_id}/message_templates?name=${encodeURIComponent(payload.name)}&fields=name,language,status`,token);
   if(current.data?.some((t:{name:string;language:string})=>t.name===payload!.name&&t.language===payload!.language))return response({error:'A template with this name and language already exists in Meta. Check approval & sync to load it, or choose another name.'},409);
   // Only the explicit Submit to Meta form creates a provider template. Sync never creates one.
   await meta(`${data.connection.waba_id}/message_templates`,token,'POST',{name:payload.name,language:payload.language,category:payload.category,...(payload.parameter_format?{parameter_format:payload.parameter_format}:{}),components:JSON.stringify(payload.components)});accepted=true;
  }
  const templates=await fetchTemplates(data.connection.waba_id,token,graphVersion),admin=backend();
  const synced=await admin.rpc('sync_whatsapp_provider_templates',{p_connection:data.connection.id,p_waba:data.connection.waba_id,p_templates:templates});if(synced.error)throw Error('Could not save template status.');
  if(payload){
   const t=templates.find(t=>t.name===payload!.name&&t.language===payload!.language),record=await admin.from('message_templates').select('id').eq('property_id',pid).eq('name',payload.name).eq('language',payload.language).maybeSingle();
   const ready=t?.provider_status==='APPROVED'&&t.supported&&t.category===payload.category.toLowerCase();
   return response({success:ready?'Meta approved this template. Continue to choose when it should be sent.':t?.provider_status==='APPROVED'?'Meta approved the template with a different category. Review its card below before selecting an event.':'Submitted to Meta. Use Check approval & sync to refresh its status.',ready,submitted:true,status:t?.provider_status??'PENDING',templateId:record.data?.id});
  }
  const ready=templates.filter(t=>t.supported&&t.provider_status==='APPROVED').length;
  return response({success:ready?`Templates updated from Meta. ${ready} approved templates are ready to choose.`:'Templates updated from Meta. None are ready yet—review the status and next steps below.',ready});
 }catch(e){
  if(accepted)return response({success:'Meta accepted the submission, but the status could not be refreshed. Use Check approval & sync before submitting it again.',submitted:true,status:'PENDING'});
  return response({error:e instanceof SetupError?e.message:payload?'Could not confirm submission. Check approval & sync before trying again. If the template appears, it was received by Meta.':'Could not refresh templates. Check the WhatsApp connection and Meta permissions, then try again.'},400);
 }
}

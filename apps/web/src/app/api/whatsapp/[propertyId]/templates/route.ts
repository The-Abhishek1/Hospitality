import{NextRequest,NextResponse}from'next/server';import{createClient}from'@/lib/supabase/server';import{backend,savedToken,graphVersion}from'@/lib/whatsapp-onboarding';import{fetchTemplates}from'../../../../../../../../packages/whatsapp-security/templates.mjs';
export const runtime='nodejs';export const maxDuration=180;
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 const response=(b:object,s=200)=>NextResponse.json(b,{status:s,headers:{'Cache-Control':'no-store'}});
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return response({error:'Open the configured hotel app address.'},403);
 const{propertyId:pid}=await params,db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return response({error:'Sign in again.'},401);
 const {data,error}=await db.rpc('whatsapp_setup_context',{p_property:pid});if(error||!data?.connection)return response({error:'Connect this hotel first. Administrator access is required.'},403);
 try{const token=await savedToken(`managed:${pid}`),templates=await fetchTemplates(data.connection.waba_id,token,graphVersion);
 const r=await backend().rpc('sync_whatsapp_provider_templates',{p_connection:data.connection.id,p_waba:data.connection.waba_id,p_templates:templates});if(r.error)throw Error('Template sync could not be saved. Check migration readiness.');return response({success:`Synchronized ${r.data} templates. Only compatible approved templates can be activated.`});
 }catch{return response({error:'Could not sync templates. Check the hotel connection, Meta permissions and onboarding migrations.'},400);}
}

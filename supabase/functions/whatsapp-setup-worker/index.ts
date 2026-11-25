import{createClient}from'npm:@supabase/supabase-js@2';
import{decryptToken}from'../_shared/whatsapp-crypto.js';
import{fetchTemplates}from'../_shared/whatsapp-templates.js';
import{prepareHotelTemplates}from'../_shared/whatsapp-default-worker.js';
const secret=Deno.env.get('WHATSAPP_WORKER_SECRET')??'';
function authorized(input:string){if(!secret||input.length!==secret.length)return false;let diff=0;for(let i=0;i<secret.length;i++)diff|=secret.charCodeAt(i)^input.charCodeAt(i);return diff===0;}
Deno.serve(async req=>{
 if(req.method!=='POST')return new Response('method not allowed',{status:405});if(!authorized(req.headers.get('x-worker-secret')??''))return new Response('forbidden',{status:403});
 const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}}),claim=await db.rpc('claim_whatsapp_default_setup');if(claim.error)return Response.json({ok:false},{status:500});const job=claim.data;if(!job)return Response.json({ok:true,created:0});
 try{
  const ref=job.connection.credentials_ref,manual=JSON.parse(Deno.env.get('WHATSAPP_TOKENS_JSON')??'{}');let token=manual[ref];
  if(ref.startsWith('managed:')){const c=await db.rpc('whatsapp_delivery_credential',{p_reference:ref});if(c.error||!c.data)throw Error();token=decryptToken(c.data,ref,Deno.env.get('WHATSAPP_ENCRYPTION_KEY'));}if(!token)throw Error();
  const deadline=AbortSignal.timeout(95000);
  const version=(Deno.env.get('WHATSAPP_GRAPH_URL')??'https://graph.facebook.com/v27.0').split('/').at(-1),root=`https://graph.facebook.com/${version}`;
  async function graph(path:string,body:object,form=false){const r=await fetch(root+'/'+path,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':form?'application/x-www-form-urlencoded':'application/json'},body:form?new URLSearchParams(Object.fromEntries(Object.entries(body).map(([k,v])=>[k,String(v)]))):JSON.stringify(body),signal:AbortSignal.any([deadline,AbortSignal.timeout(20000)])}),d=await r.json();if(!r.ok||d.error)throw Error('Meta rejected template setup. Check connection permissions and template status.');return d;}
  const result=await prepareHotelTemplates(job,{
   fetchTemplates:()=>fetchTemplates(job.connection.waba_id,token,version,((url:RequestInfo|URL,options?:RequestInit)=>fetch(url,{...options,signal:AbortSignal.any([deadline,...(options?.signal?[options.signal]:[])])}))as typeof fetch),
   create:(payload:object)=>graph(job.connection.waba_id+'/message_templates',payload),
   async uploadImage(url:string){const prefix=Deno.env.get('SUPABASE_URL')+'/storage/v1/object/public/hotel-whatsapp-photos/'+job.property_id+'/';if(!url.startsWith(prefix)||!/^[a-f0-9-]+\.jpg$/.test(url.slice(prefix.length)))throw Error();
    const image=await db.storage.from('hotel-whatsapp-photos').download(job.property_id+'/'+url.slice(prefix.length));if(image.error||!image.data||image.data.size>4*1024*1024)throw Error();
    const app=Deno.env.get('WHATSAPP_APP_ID');if(!/^\d+$/.test(app??''))throw Error('Platform Meta App ID is missing.');
    const session=await graph(app+'/uploads',{file_name:'welcome.jpg',file_length:image.data.size,file_type:'image/jpeg'},true);if(typeof session.id!=='string'||!session.id.startsWith('upload:'))throw Error();
    const response=await fetch(root+'/'+session.id,{method:'POST',headers:{Authorization:`OAuth ${token}`,file_offset:'0'},body:await image.data.arrayBuffer(),signal:AbortSignal.any([deadline,AbortSignal.timeout(20000)])}),d=await response.json();if(!response.ok||!d.h)throw Error();return d.h;
   },
   async record(slot:string,provider:string,image:string|null,error:string|null){const r=await db.rpc('record_whatsapp_default_template',{p_property:job.property_id,p_lease:job.lease,p_slot:slot,p_provider:provider,p_image:image,p_error:error});if(r.error)throw Error();},
   async sync(templates:unknown[]){const r=await db.rpc('sync_whatsapp_provider_templates',{p_connection:job.connection.id,p_waba:job.connection.waba_id,p_templates:templates});if(r.error)throw Error();}
  });
  const done=await db.rpc('finish_whatsapp_default_setup',{p_property:job.property_id,p_lease:job.lease});if(done.error)throw Error();return Response.json({ok:true,...result});
 }catch{await db.rpc('finish_whatsapp_default_setup',{p_property:job.property_id,p_lease:job.lease,p_error:'Template setup could not finish. Check the hotel connection and Meta permissions. Existing submissions will be checked before retrying.'});return Response.json({ok:false},{status:500});}
});

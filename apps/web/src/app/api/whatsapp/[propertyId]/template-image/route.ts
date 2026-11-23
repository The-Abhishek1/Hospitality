import{NextRequest,NextResponse}from'next/server';import{createClient}from'@/lib/supabase/server';import{backend}from'@/lib/whatsapp-onboarding';
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 const out=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'no-store'}});
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return out({error:'Open the configured hotel app.'},403);
 const{propertyId:pid}=await params,db=await createClient(),{data,error}=await db.rpc('whatsapp_setup_context',{p_property:pid});if(error||!data?.connection)return out({error:'Hotel administrator access and a connected number are required.'},403);
 try{const input=await req.json(),admin=backend(),{data:t}=await admin.from('message_templates').select('provider_template_id,provider_waba_id,provider_definition').eq('id',input.template_id).eq('property_id',pid).single();
 if(!t||t.provider_waba_id!==data.connection.waba_id||!t.provider_definition?.components?.some((c:{type:string;format?:string})=>c.type==='HEADER'&&c.format==='IMAGE'))return out({error:'Choose an image-header template in this hotel’s current WhatsApp account.'},400);
 const prefix=process.env.NEXT_PUBLIC_SUPABASE_URL+'/storage/v1/object/public/hotel-whatsapp-photos/'+pid+'/';if(typeof input.image_url!=='string'||!input.image_url.startsWith(prefix)||!/^[a-f0-9-]+\.(jpg|png)$/.test(input.image_url.slice(prefix.length)))return out({error:'Upload a JPEG or PNG using this hotel’s photo uploader.'},400);
 const file=await admin.storage.from('hotel-whatsapp-photos').download(pid+'/'+input.image_url.slice(prefix.length));if(file.error)return out({error:'Image unavailable.'},400);
 const saved=await admin.from('whatsapp_template_assets').upsert({property_id:pid,provider_template_id:t.provider_template_id,image_url:input.image_url});if(saved.error)throw Error();return out({success:'Delivery image saved.'});
 }catch{return out({error:'Could not save template delivery image.'},400);}
}

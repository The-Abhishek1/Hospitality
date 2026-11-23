import{NextRequest,NextResponse}from'next/server';import{randomUUID}from'node:crypto';import{createClient}from'@/lib/supabase/server';import{backend}from'@/lib/whatsapp-onboarding';import{hotelPhotoType}from'@/lib/guest-concierge';
export const runtime='nodejs';export const maxDuration=60;
const result=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'no-store'}});
async function context(pid:string){const db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return{response:result({error:'Sign in again.'},401)};const{data,error}=await db.rpc('hotel_message_resources',{p_property:pid});if(error)return{response:result({error:'Hotel administrator access required.'},403)};return{db,data};}
export async function GET(_req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){const{propertyId:pid}=await params,c=await context(pid);return c.response??result(c.data);}
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return result({error:'Open the configured hotel app address.'},403);
 const{propertyId:pid}=await params,c=await context(pid);if(c.response)return c.response;
 if(Number(req.headers.get('content-length'))>4.4*1024*1024)return result({error:'Choose a hotel image up to 4 MB.'},413);
 try{const fd=await req.formData(),file=fd.get('photo');if(!(file instanceof File)||file.size<12||file.size>4*1024*1024)return result({error:'Choose a JPEG, PNG or static WebP image up to 4 MB.'},400);
  const bytes=new Uint8Array(await file.arrayBuffer()),type=hotelPhotoType(bytes);if(!type)return result({error:'Only JPEG, PNG and WebP photos are accepted. SVG and documents are not supported.'},400);
  const admin=backend(),store=admin.storage.from('hotel-whatsapp-photos'),path=`${pid}/${randomUUID()}.${type.extension}`,upload=await store.upload(path,bytes,{contentType:type.mime,upsert:false,cacheControl:'3600'});if(upload.error)throw Error();
  const url=store.getPublicUrl(path).data.publicUrl,{data:photo,error}=await admin.from('hotel_message_photos').insert({property_id:pid,url,storage_path:path,mime_type:type.mime,name:file.name.trim().slice(0,120)||'Hotel photo'}).select('id,name,url,mime_type').single();
  if(error||!photo){await store.remove([path]);throw Error();}
  return result({url,photo});
 }catch{return result({error:'Photo upload failed. Choose a valid image and try again.'},400);}
}
export async function DELETE(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return result({error:'Open the configured hotel app address.'},403);
 const{propertyId:pid}=await params,c=await context(pid);if(c.response)return c.response;
 try{const{id}=await req.json();if(typeof id!=='string'||!/^[a-f0-9-]{36}$/.test(id))return result({error:'Choose a saved photo.'},400);
 const{error}=await c.db!.rpc('archive_hotel_message_photo',{p_property:pid,p_photo:id});if(error)return result({error:'Could not remove this hotel’s photo.'},400);
 return result({success:'Removed from the library. Existing template images are preserved.'});
 }catch{return result({error:'Choose a saved photo.'},400);}
}

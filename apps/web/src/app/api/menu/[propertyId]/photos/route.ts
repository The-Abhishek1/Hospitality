import{NextRequest,NextResponse}from'next/server';
import{randomUUID}from'node:crypto';
import{createClient}from'@/lib/supabase/server';
import{createClient as createAdmin}from'@supabase/supabase-js';
import{hotelPhotoType}from'@/lib/guest-concierge';
export const runtime='nodejs';
const reply=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'no-store'}});
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 const allowedOrigins=new Set([req.nextUrl.origin]);
 try{if(process.env.APP_URL)allowedOrigins.add(new URL(process.env.APP_URL).origin);}catch{}
 if(!allowedOrigins.has(req.headers.get('origin')??''))return reply({error:'Open this hotel app to upload a photo.'},403);
 const{propertyId:pid}=await params,db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return reply({error:'Sign in again.'},401);
 const access=await db.rpc('food_menu_access',{p_property:pid});if(access.error)return reply({error:'Menu management access required.'},403);
 if(Number(req.headers.get('content-length'))>4.4*1024*1024)return reply({error:'Use a photo up to 4 MB.'},413);
 try{
  const fd=await req.formData(),file=fd.get('photo');if(!(file instanceof File)||file.size<12||file.size>4*1024*1024)return reply({error:'Choose a JPEG, PNG or WebP photo up to 4 MB.'},400);
  const bytes=new Uint8Array(await file.arrayBuffer()),type=hotelPhotoType(bytes);if(!type)return reply({error:'Choose a JPEG, PNG or WebP image. SVG and documents are not supported.'},400);
  const admin=createAdmin(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.SUPABASE_SERVICE_ROLE_KEY!,{auth:{persistSession:false}}),store=admin.storage.from('food-menu-photos'),path=`${pid}/${randomUUID()}.${type.extension}`;
  const uploaded=await store.upload(path,bytes,{contentType:type.mime,upsert:false,cacheControl:'3600'});if(uploaded.error)throw Error();
  const url=store.getPublicUrl(path).data.publicUrl,{data:photo,error}=await admin.from('food_menu_photos').insert({property_id:pid,storage_path:path,url,mime_type:type.mime}).select('id,url').single();
  if(error||!photo){await store.remove([path]);throw Error();}return reply({photo});
 }catch{return reply({error:'Could not upload this food photo. Please try again.'},400);}
}

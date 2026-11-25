import{NextRequest,NextResponse}from'next/server';import{randomUUID}from'node:crypto';import sharp from'sharp';
import{createClient}from'@/lib/supabase/server';import{backend}from'@/lib/whatsapp-onboarding';import{validId}from'@/lib/reservations';
export const runtime='nodejs';export const maxDuration=60;
const reply=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'private, no-store'}});
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return reply({error:'Open the configured hotel app address.'},403);
 const{propertyId:pid}=await params;if(!validId(pid))return reply({error:'Hotel not found.'},404);
 const db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return reply({error:'Sign in again.'},401);
 const{data:resources,error}=await db.rpc('hotel_message_resources',{p_property:pid});if(error)return reply({error:'Hotel administrator access required.'},403);
 try{
  const raw=await req.text();if(raw.length>4000)return reply({error:'Setup request is too large.'},413);const input=JSON.parse(raw);
  if(input.action==='toggle'){const r=await db.rpc('toggle_whatsapp_defaults',{p_property:pid,p_version:Number(input.version),p_enabled:input.enabled===true});if(r.error)return reply({error:r.error.code==='40001'?r.error.message:'Could not change automation. Refresh and try again.'},400);return reply({success:input.enabled?'Approved messages will activate automatically.':'Automatic messages and guest replies are off.'});}
  const ids=input.photos;if(!Array.isArray(ids)||ids.length<3||ids.length>4||new Set(ids).size!==ids.length||ids.some(id=>!validId(id)))return reply({error:'Choose three or four different hotel photos.'},400);
  if(!resources.links?.maps_url?.startsWith('https://')||!resources.links?.review_url?.startsWith('https://'))return reply({error:'Save the hotel location and Google review links first.'},400);
  const{data:current}=await db.rpc('whatsapp_default_workspace',{p_property:pid});if(current?.setup?.configured_by)return reply({error:'Default setup is already saved. Use Customize on a template to create an approved replacement.'},400);
  const admin=backend(),store=admin.storage.from('hotel-whatsapp-photos'),prefix=process.env.NEXT_PUBLIC_SUPABASE_URL+'/storage/v1/object/public/hotel-whatsapp-photos/'+pid+'/',tiles:{input:Buffer;left:number;top:number}[]=[];
  for(let i=0;i<ids.length;i++){
   const photo=resources.photos.find((p:{id:string})=>p.id===ids[i]);if(!photo?.url.startsWith(prefix)||!/^[a-f0-9-]+\.(jpg|png|webp)$/.test(photo.url.slice(prefix.length)))return reply({error:'Choose photos uploaded for this hotel.'},400);
   const path=pid+'/'+photo.url.slice(prefix.length),file=await store.download(path);if(file.error||!file.data||file.data.size>4*1024*1024)throw Error('Photo unavailable.');
   const width=ids.length===3&&i===2?1280:640;const image=await sharp(Buffer.from(await file.data.arrayBuffer()),{limitInputPixels:24_000_000,animated:false}).rotate().resize(width,480,{fit:'cover'}).jpeg({quality:82}).toBuffer();tiles.push({input:image,left:i===1||i===3?640:0,top:i>=2?480:0});
  }
  const collage=await sharp({create:{width:1280,height:960,channels:3,background:'#ffffff'}}).composite(tiles).jpeg({quality:86}).toBuffer(),path=`${pid}/${randomUUID()}.jpg`,upload=await store.upload(path,collage,{contentType:'image/jpeg',upsert:false});if(upload.error)throw Error();const url=store.getPublicUrl(path).data.publicUrl;
  const inserted=await admin.from('hotel_message_photos').insert({property_id:pid,name:'Booking welcome collage',url,storage_path:path,mime_type:'image/jpeg'}).select('id').single();if(inserted.error){await store.remove([path]);throw Error();}
  const saved=await admin.rpc('save_whatsapp_default_setup',{p_property:pid,p_actor:user.id,p_version:Number(input.version)||0,p_photos:ids,p_image:url});if(saved.error){await admin.from('hotel_message_photos').delete().eq('id',inserted.data.id);await store.remove([path]);return reply({error:['22023','40001'].includes(saved.error.code)?saved.error.message:'Could not save default setup.'},400);}
  return reply({success:'Default messages are being prepared and submitted. Assignments update automatically as Meta approves them.'});
 }catch{return reply({error:'Could not finish setup. Check the selected photos and hotel connection, then try again.'},400);}
}

import{NextRequest,NextResponse}from'next/server';import{randomUUID}from'node:crypto';import{createClient}from'@/lib/supabase/server';import{backend}from'@/lib/whatsapp-onboarding';import{hotelPhotoType}from'@/lib/guest-concierge';
export const runtime='nodejs';export const maxDuration=60;
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 const result=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'no-store'}});
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return result({error:'Open the configured hotel app address.'},403);
 const{propertyId:pid}=await params,db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return result({error:'Sign in again.'},401);
 const{error}=await db.rpc('whatsapp_setup_context',{p_property:pid});if(error)return result({error:'Hotel administrator access required.'},403);
 if(Number(req.headers.get('content-length'))>4.4*1024*1024)return result({error:'Choose a hotel image up to 4 MB.'},413);
 try{const fd=await req.formData(),file=fd.get('photo');if(!(file instanceof File)||file.size<12||file.size>4*1024*1024)return result({error:'Choose a JPEG, PNG or static WebP image up to 4 MB.'},400);
  const bytes=new Uint8Array(await file.arrayBuffer()),type=hotelPhotoType(bytes);if(!type)return result({error:'Only JPEG, PNG and WebP photos are accepted. SVG and documents are not supported.'},400);
  const store=backend().storage.from('hotel-whatsapp-photos'),path=`${pid}/${randomUUID()}.${type.extension}`,upload=await store.upload(path,bytes,{contentType:type.mime,upsert:false,cacheControl:'3600'});if(upload.error)throw Error();
  return result({url:store.getPublicUrl(path).data.publicUrl});
 }catch{return result({error:'Photo upload failed. Choose a valid image and try again.'},400);}
}

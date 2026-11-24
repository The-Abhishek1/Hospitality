import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {backend} from '@/lib/whatsapp-onboarding';
import {validId} from '@/lib/reservations';
export async function GET(_req:Request,{params}:{params:Promise<{propertyId:string;messageId:string}>}){
 const{propertyId:pid,messageId}=await params,headers={'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer'};
 if(!validId(pid)||!validId(messageId))return new NextResponse('Photo not found.',{status:404,headers});
 const db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return new NextResponse('Sign in to view this photo.',{status:401,headers});
 const{data:message}=await db.from('messages').select('inbox_photo_id').eq('id',messageId).eq('property_id',pid).eq('direction','out').maybeSingle();
 const{data:photo}=message?.inbox_photo_id?await db.from('inbox_photo_uploads').select('storage_path').eq('id',message.inbox_photo_id).eq('property_id',pid).maybeSingle():{data:null};
 if(!photo)return new NextResponse('Photo not found.',{status:404,headers});
 const{data,error}=await backend().storage.from('whatsapp-inbox-photos').createSignedUrl(photo.storage_path,300);
 return error||!data?new NextResponse('Photo unavailable.',{status:404,headers}):new NextResponse(null,{status:302,headers:{...headers,Location:data.signedUrl}});
}

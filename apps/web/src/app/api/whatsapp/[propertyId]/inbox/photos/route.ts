import {NextRequest,NextResponse} from 'next/server';
import {revalidatePath} from 'next/cache';
import {queueInboxPhoto} from '@/lib/inbox-photo';
export const runtime='nodejs';
export const maxDuration=60;
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 const reply=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'no-store'}});
 if(req.headers.get('origin')!==(process.env.WHATSAPP_ONBOARDING_ORIGIN||req.nextUrl.origin))return reply({error:'Open the configured hotel app address.'},403);
 if(Number(req.headers.get('content-length'))>4.4*1024*1024)return reply({error:'Choose a JPG or PNG up to 4 MB.'},413);
 const{propertyId:pid}=await params;
 try{const messageId=await queueInboxPhoto(pid,await req.formData());revalidatePath(`/p/${pid}/inbox`);revalidatePath('/dashboard');return reply({messageId,success:'Photo queued. Delivery status will appear in this chat.'});}
 catch(error){return reply({error:error instanceof Error?error.message:'Photo could not be sent. Try again.'},400);}
}

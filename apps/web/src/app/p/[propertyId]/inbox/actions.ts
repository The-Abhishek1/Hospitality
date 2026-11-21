"use server";
import {revalidatePath} from 'next/cache';
import {createClient} from '@/lib/supabase/server';
import {validId} from '@/lib/reservations';
export type InboxState={error?:string;success?:string;messageId?:string;request?:string;body?:string;template?:string};
const field=(fd:FormData,k:string)=>String(fd.get(k)??'').trim();
function friendly(e:{code?:string;message:string}){return e.code==='42501'?'Your role does not allow this action.':e.code==='40001'?'This conversation changed. Refresh before continuing.':e.code==='23505'?'This business number is already assigned to another hotel.':e.code==='22023'?e.message:'Couldn’t complete this action. Refresh and try again.';}
async function context(fd:FormData){
 const pid=field(fd,'pid'),cid=field(fd,'cid');if(!validId(pid)||!validId(cid))return null;
 const db=await createClient();const {data,error}=await db.from('conversations').select('id').eq('id',cid).eq('property_id',pid).maybeSingle();return !error&&data?{db,pid,cid}:null;
}
export async function sendMessage(_:InboxState,fd:FormData):Promise<InboxState>{
 const c=await context(fd);if(!c)return{error:'Conversation not found in this hotel.'};
 const request=field(fd,'request'),body=field(fd,'body'),template=field(fd,'template');
 const preserved={body,template};if(!validId(request)||(template&&!validId(template)))return{error:'Reload the reply form and try again.',...preserved};
 if(!template&&(body.length<1||body.length>4096))return{error:'Write a reply between 1 and 4096 characters.',...preserved};
 const {data,error}=await c.db.rpc('inbox_send',{p_conversation:c.cid,p_request:request,p_body:body||null,p_template:template||null});
 if(error)return{error:friendly(error),...preserved};revalidatePath(`/p/${c.pid}/inbox`);revalidatePath('/dashboard');return{success:'Reply queued. Delivery is handled by the WhatsApp worker.',messageId:data,request};
}
export async function conversationAction(_:InboxState,fd:FormData):Promise<InboxState>{
 const c=await context(fd);if(!c)return{error:'Conversation not found in this hotel.'};
 const action=field(fd,'action'),user=field(fd,'user');if(!['claim','assign','release','close','reopen','human_on','human_off'].includes(action)||(user&&!validId(user)))return{error:'Choose a valid conversation action.'};
 const {error}=await c.db.rpc('inbox_manage',{p_conversation:c.cid,p_version:Number(fd.get('version')),p_action:action,p_user:user||null});
 if(error)return{error:friendly(error)};revalidatePath(`/p/${c.pid}/inbox`);revalidatePath('/dashboard');return{success:'Conversation updated.'};
}
export async function retryMessage(_:InboxState,fd:FormData):Promise<InboxState>{
 const c=await context(fd),id=field(fd,'message');if(!c||!validId(id))return{error:'Message not found.'};
 const {data}=await c.db.from('messages').select('id').eq('id',id).eq('conversation_id',c.cid).maybeSingle();if(!data)return{error:'Message not found in this conversation.'};
 const {error}=await c.db.rpc('inbox_retry',{p_message:id});if(error)return{error:friendly(error)};revalidatePath(`/p/${c.pid}/inbox`);return{success:'Message queued for retry.'};
}
export async function markRead(pid:string,cid:string,message:string):Promise<{error?:string}>{
 if(!validId(pid)||!validId(cid)||!validId(message))return{error:'Couldn’t update read status.'};const fd=new FormData();fd.set('pid',pid);fd.set('cid',cid);const c=await context(fd);if(!c)return{error:'Conversation unavailable.'};
 const {error}=await c.db.rpc('inbox_mark_read',{p_conversation:cid,p_message:message});if(error)return{error:friendly(error)};return{};
}
export async function configureWhatsApp(_:InboxState,fd:FormData):Promise<InboxState>{
 const pid=field(fd,'pid');if(!validId(pid))return{error:'Property not found.'};const status=field(fd,'status');
 if(status==='active'&&field(fd,'ready')!=='yes')return{error:'Confirm that the business number and server credentials are ready before enabling delivery.'};
 const db=await createClient();const {error}=await db.rpc('inbox_configure',{p_property:pid,p_phone_id:field(fd,'phone_id'),p_waba_id:field(fd,'waba_id'),p_display:field(fd,'display'),p_credentials_ref:field(fd,'credentials_ref'),p_status:status});
 if(error)return{error:friendly(error)};revalidatePath(`/p/${pid}/inbox`);return{success:status==='active'?'Messaging enabled. Use the inbox to monitor actual delivery status.':'WhatsApp configuration saved.'};
}

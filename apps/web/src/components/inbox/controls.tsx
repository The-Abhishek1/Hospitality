"use client";
import {displayDateTime} from '@/lib/date-format';

import {useEffect,useRef,useState,useTransition,useActionState} from 'react';
import {useRouter} from 'next/navigation';
import {conversationAction,configureWhatsApp,markRead,retryMessage,type InboxState} from '@/app/p/[propertyId]/inbox/actions';
import type {Conversation,InboxData} from '@/lib/inbox';
export function InboxRefresh(){
 const router=useRouter(),[pending,start]=useTransition();const [auto,setAuto]=useState(true);const busy=useRef(false);
 useEffect(()=>{busy.current=pending;},[pending]);
 useEffect(()=>{if(!auto)return;const timer=setInterval(()=>{const el=document.activeElement;if(!busy.current&&document.visibilityState==='visible'&&!el?.matches('textarea,input,select'))start(()=>router.refresh());},15000);return()=>clearInterval(timer);},[router,auto]);
 return <div className="ib-refresh"><label><input type="checkbox" checked={auto} onChange={e=>setAuto(e.target.checked)}/>Live</label><button className="dash-button dash-secondary" onClick={()=>start(()=>router.refresh())} disabled={pending}>{pending?'Refreshing…':'↻ Refresh'}</button></div>;
}
export function ThreadBehavior({children,pid,cid,lastInbound,lastMessage,history}:{children:React.ReactNode;pid:string;cid:string;lastInbound?:string;lastMessage?:string;history:boolean}){
 const feed=useRef<HTMLDivElement>(null),atBottom=useRef(true),marked=useRef(''),last=useRef(''),viewHeight=useRef(0),viewWidth=useRef(0);const router=useRouter();const [newer,setNewer]=useState(false),[readError,setReadError]=useState('');
 useEffect(()=>{if(history)return;const el=feed.current;if(!el)return;
  const read=()=>{if(!lastInbound||marked.current===lastInbound||document.visibilityState!=='visible'||!el.getClientRects().length||!atBottom.current)return;
   marked.current=lastInbound;markRead(pid,cid,lastInbound).then(result=>{if(result.error){setReadError(result.error);marked.current='';}else{setReadError('');router.refresh();}}).catch(()=>{marked.current='';setReadError('Read status couldn’t be updated.');});};
  const scroll=()=>{if(viewHeight.current!==el.clientHeight||viewWidth.current!==el.clientWidth){viewHeight.current=el.clientHeight;viewWidth.current=el.clientWidth;if(atBottom.current)el.scrollTop=el.scrollHeight;return;}atBottom.current=el.scrollHeight-el.scrollTop-el.clientHeight<100;if(atBottom.current){setNewer(false);read();}};
  viewHeight.current=el.clientHeight;viewWidth.current=el.clientWidth;
  if(atBottom.current||!last.current){el.scrollTop=el.scrollHeight;read();}else if(lastMessage!==last.current)setNewer(true);
  last.current=lastMessage??'';el.addEventListener('scroll',scroll);document.addEventListener('visibilitychange',read);window.addEventListener('focus',read);
  const resize=new ResizeObserver(()=>{if(atBottom.current&&el.getClientRects().length){el.scrollTop=el.scrollHeight;read();}});resize.observe(el);
  return()=>{resize.disconnect();el.removeEventListener('scroll',scroll);document.removeEventListener('visibilitychange',read);window.removeEventListener('focus',read);};
 },[pid,cid,lastInbound,lastMessage,history,router]);
 return <><div className="ib-message-feed" ref={feed} role="region" tabIndex={0} aria-label="Message history">{children}</div>{newer&&<button className="ib-new-messages" onClick={()=>{const el=feed.current;if(el){atBottom.current=true;el.scrollTop=el.scrollHeight;setNewer(false);}}}>New messages ↓</button>}{readError&&<p className="ib-feedback error" role="status">{readError}</p>}</>;
}
export function ConversationPauseNotice({pid,c,tz}:{pid:string;c:Conversation;tz:string}){
 const[state,action,pending]=useActionState(conversationAction,{} as InboxState);
 if(!c.human_handoff)return null;
 const origin=c.handoff_origin==='staff'?`Paused by ${c.handoff_actor_name||'a staff member'}`:c.handoff_origin==='automation'?'Paused by an automated handoff':'The person or action that set this earlier pause was not recorded';
 return <aside className="ib-automation-paused" aria-label="Conversation automation paused"><div><strong>Automatic messages are paused for this chat</strong><p>Human handling pauses guest-menu replies and automatic event messages, including the booking welcome.</p><small>{origin}{c.handoff_changed_at&&` · ${displayDateTime(new Date(c.handoff_changed_at),tz)}`}</small><p>Turning on hotel automation keeps this conversation in human handling until you resume it here.</p></div><form action={action}><input type="hidden" name="pid" value={pid}/><input type="hidden" name="cid" value={c.id}/><input type="hidden" name="version" value={c.version}/><button className="dash-button" name="action" value="human_off" disabled={pending}>{pending?'Resuming…':'Allow automation'}</button>{state.error&&<p role="alert">{state.error}</p>}</form></aside>;
}
export function ConversationControls({pid,c,canAssign,assignees,userId}:{pid:string;c:Conversation;canAssign:boolean;assignees:InboxData['assignees'];userId:string}){
 const [state,action,pending]=useActionState(conversationAction,{} as InboxState);
 return <form action={action} className="ib-conversation-controls"><input type="hidden" name="pid" value={pid}/><input type="hidden" name="cid" value={c.id}/><input type="hidden" name="version" value={c.version}/><div className="ib-control-buttons">
 {!c.assigned_to&&<button name="action" value="claim" disabled={pending}>Assign to me</button>}
 {(c.assigned_to===userId||canAssign)&&c.assigned_to&&<button name="action" value="release" disabled={pending}>Unassign</button>}
 <button name="action" value={c.status==='closed'?'reopen':'close'} disabled={pending}>{c.status==='closed'?'Reopen':'Resolve'}</button>
 <button name="action" value={c.human_handoff?'human_off':'human_on'} disabled={pending}>{c.human_handoff?'Allow automation':'Human handling'}</button>
 </div>{canAssign&&<div className="ib-assign"><label htmlFor="ib-assignee">Assign conversation</label><select id="ib-assignee" name="user" defaultValue={c.assigned_to??''}><option value="">Unassigned</option>{assignees.map(u=><option key={u.id} value={u.id}>{u.name}</option>)}</select><button name="action" value="assign" disabled={pending}>Save</button></div>}
 {state.error&&<p className="ib-feedback error" role="alert">{state.error}</p>}{state.success&&<p className="ib-feedback success" role="status">{state.success}</p>}</form>;
}
export function RetryMessage({pid,cid,id}:{pid:string;cid:string;id:string}){
 const [state,action,pending]=useActionState(retryMessage,{} as InboxState);
 return <form action={action} className="ib-retry"><input type="hidden" name="pid" value={pid}/><input type="hidden" name="cid" value={cid}/><input type="hidden" name="message" value={id}/><button disabled={pending}>{pending?'Queuing…':'Retry message'}</button>{state.error&&<span role="alert">{state.error}</span>}{state.success&&<span role="status">{state.success}</span>}</form>;
}
export function WhatsAppSetup({pid,connection}:{pid:string;connection:InboxData['connection']}){
 const [state,action,pending]=useActionState(configureWhatsApp,{} as InboxState);
 const [fields,setFields]=useState({phone_id:connection?.phone_number_id??'',waba_id:connection?.waba_id??'',display:connection?.display_phone??'',credentials_ref:'',status:connection?.status??'pending'});
 const set=(k:keyof typeof fields,v:string)=>setFields(f=>({...f,[k]:v}));
 return <section className="ib-setup"><div><span className="dash-eyebrow">WHATSAPP BUSINESS</span><h2>{connection?'Connection settings':'Connect your hotel number'}</h2><p>Register the number details and the credential reference configured by your administrator. Saving these details does not verify the number with Meta.</p></div><form action={action}><input type="hidden" name="pid" value={pid}/><fieldset disabled={pending}><div className="ib-setup-grid">
 <label>Phone number ID<input name="phone_id" inputMode="numeric" pattern="[0-9]{5,30}" minLength={5} maxLength={30} required value={fields.phone_id} onChange={e=>set('phone_id',e.target.value)}/></label>
 <label>WhatsApp Business Account ID<input name="waba_id" inputMode="numeric" pattern="[0-9]{5,30}" minLength={5} maxLength={30} required value={fields.waba_id} onChange={e=>set('waba_id',e.target.value)}/></label>
 <label>Display phone number<input name="display" type="tel" maxLength={40} value={fields.display} onChange={e=>set('display',e.target.value)} placeholder="+91…"/></label>
 <label>Credential reference<input name="credentials_ref" required maxLength={100} value={fields.credentials_ref} onChange={e=>set('credentials_ref',e.target.value)} placeholder="e.g. vault:hotel-whatsapp"/><small>Enter the saved server reference, never an access token. Re-enter it to save settings.</small></label>
 <label>Messaging status<select name="status" value={fields.status} onChange={e=>set('status',e.target.value)}><option value="pending">Pending setup</option><option value="active">Enabled</option><option value="disabled">Disabled</option></select></label>
 </div>{fields.status==='active'&&<label className="ib-ready"><input type="checkbox" name="ready" value="yes" required/>I confirm the number is verified and the webhook, server credentials, and delivery worker are configured.</label>}</fieldset>
 {state.error&&<p className="ib-feedback error" role="alert">{state.error}</p>}{state.success&&<p className="ib-feedback success" role="status">{state.success}</p>}<button className="dash-button" disabled={pending}>{pending?'Saving…':'Save WhatsApp configuration'}</button></form><p className="ib-setup-note">Approved templates must already be registered with Meta and synchronized into the hotel’s template catalog. Template submission, media viewing, and automated reply rules are not configured on this screen.</p></section>;
}

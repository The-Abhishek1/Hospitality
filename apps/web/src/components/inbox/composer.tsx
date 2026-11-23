"use client";
import {useActionState,useEffect,useState} from 'react';
import {sendMessage,type InboxState} from '@/app/p/[propertyId]/inbox/actions';
import type {Conversation,InboxTemplate} from '@/lib/inbox';
export function Composer({pid,c,templates,enabled,request}:{pid:string;c:Conversation;templates:InboxTemplate[];enabled:boolean;request:string}){
 const [state,action,pending]=useActionState(sendMessage,{} as InboxState);
 const [body,setBody]=useState(state.body??''),[template,setTemplate]=useState(state.template??''),[requestId,setRequestId]=useState(request);
 const [windowOpen,setWindowOpen]=useState(!!c.window_open);
 const [mode,setMode]=useState<'text'|'template'>(c.window_open?'text':'template');
 useEffect(()=>{const update=()=>setWindowOpen(!!c.window_ends_at&&Date.parse(c.window_ends_at)>Date.now());update();const timer=setInterval(update,15000);return()=>clearInterval(timer);},[c.window_ends_at]);
 useEffect(()=>{if(!windowOpen)setMode('template');},[windowOpen]);
 useEffect(()=>{if(state.messageId){setBody('');setTemplate('');setRequestId(crypto.randomUUID());}},[state.messageId]);
 const t=templates.find(t=>t.id===template),supported=templates.filter(t=>t.supported);
 if(c.opted_out)return <div className="ib-composer-locked"><strong>Contact opted out</strong><p>Replies are blocked. The contact must opt in again before you can send a message.</p></div>;
 if(c.status==='closed')return <div className="ib-composer-locked"><strong>This conversation is resolved</strong><p>Reopen it to reply. New incoming messages also reopen the conversation.</p></div>;
 if(!enabled)return <div className="ib-composer-locked"><strong>Messaging is not enabled</strong><p>Ask your hotel administrator to finish WhatsApp setup before replying.</p></div>;
 return <form action={action} className="ib-composer"><input type="hidden" name="pid" value={pid}/><input type="hidden" name="cid" value={c.id}/><input type="hidden" name="request" value={requestId}/>
 <div className="ib-composer-heading"><span>{mode==='text'?'Reply to guest':'Approved template'}</span><div><button type="button" aria-pressed={mode==='text'} disabled={!windowOpen||pending} onClick={()=>setMode('text')}>Free text</button><button type="button" aria-pressed={mode==='template'} disabled={pending} onClick={()=>setMode('template')}>Template</button></div></div>
 {mode==='text'?<label className="ib-reply-label"><span className="sr-only">Reply message</span><textarea name="body" rows={2} maxLength={4096} required value={body} onChange={e=>setBody(e.target.value)} disabled={pending} placeholder="Type a message…"/></label>:<div className="ib-template-picker"><label htmlFor="ib-template">Choose an approved template</label><select id="ib-template" name="template" value={template} onChange={e=>setTemplate(e.target.value)} disabled={pending} required><option value="">Select template…</option>{supported.map(t=><option key={t.id} value={t.id}>{t.name} · {t.language}</option>)}</select>{t&&<details className="ib-template-preview"><summary>Preview template · {t.language}</summary><p>{t.body}</p></details>}{!supported.length&&<p>No supported approved templates are available for this hotel. Ask an administrator to synchronize them.</p>}{templates.some(t=>!t.supported)&&<small>Templates with guest fields are sent through WhatsApp Automation.</small>}</div>}
 {state.error&&<p className="ib-feedback error" role="alert">{state.error}</p>}{state.success&&<p className="ib-feedback success" role="status">{state.success}</p>}
 <div className="ib-composer-footer"><p>{windowOpen?'Customer-service reply window is open.':'Reply window closed. Choose an approved template.'}{mode==='text'&&<span>{body.length} / 4096</span>}</p><button className="dash-button" disabled={pending||(mode==='text'?!body.trim():!t?.supported)}>{pending?'Queuing…':'Send message ↑'}</button></div>
 </form>;
}

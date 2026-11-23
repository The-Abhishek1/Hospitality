'use client';
import{useActionState,useEffect,useState}from'react';import{sendGuestReply}from'@/app/p/[propertyId]/inbox/actions';
import{conciergeActions,type ConciergeConfig}from'@/lib/guest-concierge';
export function GuestQuickReplies({pid,cid,config,windowEnds}:{pid:string;cid:string;config:ConciergeConfig|null;windowEnds:string|null}){
 const[state,action,pending]=useActionState(sendGuestReply,{}),[request,setRequest]=useState(''),[open,setOpen]=useState(false);
 useEffect(()=>{setRequest(crypto.randomUUID());const check=()=>setOpen(Boolean(windowEnds&&Date.parse(windowEnds)>Date.now()));check();const timer=setInterval(check,15000);return()=>clearInterval(timer);},[windowEnds]);useEffect(()=>{if(state.messageId)setRequest(crypto.randomUUID());},[state.messageId]);
 if(!config)return null;
 return <form action={action} className="ib-guest-quick-replies"><input type="hidden" name="pid" value={pid}/><input type="hidden" name="cid" value={cid}/><input type="hidden" name="request" value={request}/><strong>Share hotel information</strong><small>Links, menus and photos need an open reply window. Private pages require a verified guest and one eligible stay.</small><div><button name="guest_action" value="menu" disabled={!open||pending||!request}>Send guest menu</button>{(config.data.categories?config.data.categories.filter(c=>c.enabled).flatMap(c=>c.services.filter(s=>s.enabled).map(s=>({action:'service:'+s.id,label:s.label}))):config.data.items.filter(i=>i.enabled)).map(i=><button key={i.action} name="guest_action" value={i.action} disabled={!open||pending||!request}>{i.label}</button>)}</div>{state.error&&<p role="alert" className="ib-feedback error">{state.error}</p>}{state.success&&<p role="status" className="ib-feedback success">{state.success}</p>}</form>;
}

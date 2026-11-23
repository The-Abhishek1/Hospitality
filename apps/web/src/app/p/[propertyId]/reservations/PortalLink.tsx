"use client";
import { useActionState,useState } from 'react';
import { createPortalLink } from './portal-link-action';
export default function PortalLink({reservationId}:{reservationId:string}){
 const [state,action,pending]=useActionState(createPortalLink,null);
 const [copyStatus,setCopyStatus]=useState('');
 return <form action={action} className="flex items-center gap-2 flex-wrap">
  <input type="hidden" name="reservation" value={reservationId}/>
  <select name="task" aria-label="Guest task" className="rounded border border-slate-300 px-2 py-1 text-xs" defaultValue="documents"><option value="documents">Document upload</option><option value="food">Order food</option><option value="bill">View bill</option><option value="stay">Stay details</option></select>
  <button disabled={pending} className="rounded border border-slate-300 px-2 py-0.5 text-xs hover:bg-slate-100">{pending?'Creating link…':state?.link?'Create another link':'Create task link'}</button>
  {state?.link&&<><input readOnly aria-label="Private guest task link" value={state.link} onFocus={e=>e.currentTarget.select()} className="w-48 rounded border px-1 py-0.5 text-xs"/><button type="button" className="rounded border border-slate-300 px-2 py-0.5 text-xs" onClick={async()=>{try{await navigator.clipboard.writeText(state.link!);setCopyStatus('Link copied.');}catch{setCopyStatus('Select the link and copy it manually.');}}}>Copy link</button><span role="status" className="text-xs text-slate-500">{copyStatus}</span></>}
  {state?.error&&<span role="alert" className="text-xs text-red-600">{state.error}</span>}
 </form>;
}

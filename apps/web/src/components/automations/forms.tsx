'use client';
import{useActionState,useState}from'react';import{useRouter}from'next/navigation';import{saveAutomation}from'@/app/p/[propertyId]/automations/actions';
export type Template={id:string;name:string;language:string;body:string;category:string;status:string;supported:boolean;parameters:string[];checked_at:string};
export type Rule={event_key:string;enabled:boolean;version:number;template_id:string;parameter_keys:string[];delay_minutes:number};
export type Stay={id:string;guest_id:string;full_name:string;phone:string|null;check_in:string;check_out:string;status:string;permission:string|null;permission_version:number|null};
const fields=['guest_name','hotel_name','booking_reference','check_in','check_out','hotel_phone','room_name','event_label','order_reference','request_title','amount','currency','invoice_number','portal_url','review_url'];
const labels:Record<string,string>={guest_name:'Guest name',hotel_name:'Hotel name',booking_reference:'Booking reference',check_in:'Arrival date',check_out:'Departure date',hotel_phone:'Hotel phone',room_name:'Room',event_label:'Event description',order_reference:'Order reference',request_title:'Guest request title',amount:'Amount for this event',currency:'Currency',invoice_number:'Invoice number',portal_url:'Secure guest portal link',review_url:'Public review URL'};
function Notice({state}:{state:{error?:string;success?:string}}){return state.error||state.success?<p role="status" className={`auto-notice ${state.error?'error':''}`}>{state.error??state.success}</p>:null;}
export function AutomationRule({pid,event,rule,templates}:{pid:string;event:{key:string;label:string;scheduled:boolean};rule?:Rule;templates:Template[]}){
 const[state,action,pending]=useActionState(saveAutomation,{}),[tid,setTid]=useState(rule?.template_id??''),[keys,setKeys]=useState<string[]>(rule?.parameter_keys??[]);
 const eligible=templates.filter(t=>t.supported&&t.status==='APPROVED'&&t.category===(event.key==='review_request'?'marketing':'utility')),template=eligible.find(t=>t.id===tid);
 function choose(id:string){setTid(id);const t=eligible.find(t=>t.id===id);setKeys(t?.parameters.map((name,i)=>fields.includes(name)?name:['guest_name','hotel_name','event_label','booking_reference'][i]??'event_label')??[]);}
 return <form action={action} className="auto-rule"><input type="hidden" name="pid" value={pid}/><input type="hidden" name="kind" value="rule"/><input type="hidden" name="event" value={event.key}/><input type="hidden" name="version" value={rule?.version??0}/><input type="hidden" name="keys" value={JSON.stringify(keys)}/>
 <div className="auto-rule-title"><h3>{event.label}</h3><span>{rule?.enabled?'Enabled':'Off'}</span></div>
 <label>Approved template<select name="template" value={tid} onChange={e=>choose(e.target.value)}><option value="">Select a synced template</option>{eligible.map(t=><option key={t.id} value={t.id}>{t.name} · {t.language}</option>)}</select></label>
 {template&&<><p className="auto-template-preview">{template.body}</p>{template.parameters.map((name,i)=><label key={name}>Value for {`{{${name}}}`}<select value={keys[i]??''} onChange={e=>setKeys(old=>old.map((v,j)=>j===i?e.target.value:v))}>{fields.map(f=><option key={f} value={f}>{labels[f]}</option>)}</select></label>)}</>}
 <label>{event.key==='arrival_reminder'||event.key==='checkout_reminder'?'Minutes before hotel arrival / checkout time':'Minutes after event'}<input name="delay" type="number" min="0" max="10080" defaultValue={rule?.delay_minutes??(event.key==='arrival_reminder'?1440:event.key==='checkout_reminder'?120:event.key==='review_request'?1440:0)}/></label>
 <label className="auto-check"><input name="enabled" type="checkbox" defaultChecked={rule?.enabled??false}/>Enable for new eligible events</label>
 {!eligible.length&&<small>Sync a compatible Meta-approved {event.key==='review_request'?'marketing':'utility'} template first.</small>}
 <Notice state={state}/><button className="dash-button dash-secondary" disabled={pending}>{pending?'Saving…':'Save rule'}</button></form>;
}
export function TemplateSync({pid}:{pid:string}){const[busy,setBusy]=useState(false),[notice,setNotice]=useState(''),router=useRouter();async function sync(){setBusy(true);try{const r=await fetch(`/api/whatsapp/${pid}/templates`,{method:'POST'}),d=await r.json();setNotice(d.error??d.success);if(r.ok)router.refresh();}catch{setNotice('Template sync failed. Refresh and try again.');}finally{setBusy(false);}}return <div><button className="dash-button" onClick={sync} disabled={busy}>{busy?'Synchronizing…':'Sync approved templates from Meta'}</button>{notice&&<p role="status">{notice}</p>}</div>;}
export function StayPermission({pid,stays}:{pid:string;stays:Stay[]}){
 const[state,action,pending]=useActionState(saveAutomation,{}),[rid,setRid]=useState(stays[0]?.id??''),stay=stays.find(s=>s.id===rid);
 return <form action={action} className="auto-permission" key={rid}><input type="hidden" name="pid" value={pid}/><input type="hidden" name="kind" value="permission"/><input type="hidden" name="reservation" value={rid}/><input type="hidden" name="version" value={stay?.permission_version??0}/>
 <label>Recent stay<select value={rid} onChange={e=>setRid(e.target.value)}>{stays.map(s=><option key={s.id} value={s.id}>{s.full_name} · {s.check_in} → {s.check_out} · {s.phone??'No phone'}</option>)}</select></label>
 <p>Current permission: <strong>{stay?.permission??'Not recorded'}</strong>. Matching guest profiles can use this permission for future stays at this hotel until revoked. A previous booking is not permission.</p>
 <label>Stay updates<select name="status" defaultValue={stay?.permission??'granted'}><option value="granted">Guest agreed to operational stay updates</option><option value="revoked">Revoke stay-update permission</option></select></label>
 <label>Permission evidence<textarea name="evidence" required minLength={10} maxLength={1000} rows={3} placeholder="For example: guest confirmed this WhatsApp number and signed the stay-updates opt-in at reception today."/></label>
 <label className="auto-check"><input name="confirmed" type="checkbox" required/>I verified the guest identity, phone number and their permission decision.</label>
 <Notice state={state}/><button className="dash-button dash-secondary" disabled={pending||!stay}>{pending?'Saving…':'Save guest permission'}</button></form>;
}

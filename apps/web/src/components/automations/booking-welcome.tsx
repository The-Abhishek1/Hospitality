'use client';
import {useActionState,useState} from 'react';
import Link from 'next/link';
import {saveBookingWelcome} from '@/app/p/[propertyId]/automations/actions';
import {previewAutomation,automationStarters} from '@/lib/automation-flow';
import {welcomeKeys} from '@/lib/booking-welcome';
import {TemplateSync,type Rule,type Template} from './forms';
import type {ServiceTemplate} from '@/lib/guest-concierge';
export function BookingWelcome({pid,rule,templates,serviceTemplates,connected,workerReady,menuReady,selectedTemplate}:{pid:string;rule?:Rule;templates:Template[];serviceTemplates:ServiceTemplate[];connected:boolean;workerReady:boolean;menuReady:boolean;selectedTemplate?:string}){
 const[state,action,pending]=useActionState(saveBookingWelcome,{}),[tid,setTid]=useState(selectedTemplate??rule?.template_id??'');
 const template=templates.find(t=>t.id===tid),keys=template?welcomeKeys(template,tid===rule?.template_id?rule.parameter_keys:undefined):null;
 const service=serviceTemplates.find(t=>t.id===tid),photo=service?.image_url,needsPhoto=service?.definition?.components.some(c=>c.type==='HEADER'&&c.format==='IMAGE')&&!photo,changed=tid!==(rule?.template_id??'');
 const ready=connected&&Boolean(keys)&&!needsPhoto,on=Boolean(rule?.enabled),base=`/p/${pid}/automations`;
 return <section className="auto-panel auto-welcome"><div className="auto-heading"><div><h2>Booking welcome</h2><p>Send hotel and stay details with a personal document-upload link.</p></div><span className={`auto-status ${on?'ready':''}`}>{on?'On':'Off'}</span></div>
 <form action={action}><input type="hidden" name="pid" value={pid}/><input type="hidden" name="version" value={rule?.version??0}/><input type="hidden" name="keys" value={JSON.stringify(keys??[])}/>
 <div className="auto-welcome-toggle"><div><strong>Send booking welcome automatically</strong><small>{on?'New eligible bookings receive the selected message.':'Booking welcomes are paused.'}</small></div><button className="auto-switch" type="submit" name="intent" value={on?'off':'on'} role="switch" aria-checked={on} aria-label="Automatic booking welcome" disabled={pending||(!on&&(!ready||changed))}><span/>{on?'On':'Off'}</button></div>
 <label>Welcome message<select name="template" value={tid} disabled={pending} onChange={e=>setTid(e.target.value)}><option value="">Choose an approved welcome</option>{templates.filter(t=>t.id===tid||welcomeKeys(t)).map(t=><option value={t.id} key={t.id}>{t.name} · {t.language}{!welcomeKeys(t,t.id===rule?.template_id?rule.parameter_keys:undefined)?' · needs attention':''}</option>)}</select></label>
 <details className="auto-welcome-preview"><summary>Preview welcome message</summary><div className="auto-message-example"><span className="dash-eyebrow">{template?'MESSAGE PREVIEW · SAMPLE GUEST':'PREDEFINED WELCOME · EDIT BEFORE SUBMITTING'}</span>{photo&&<img src={photo} alt="Welcome photo" width="240"/>}<p>{previewAutomation(template?.body??automationStarters.booking_confirmed,keys??undefined,template?.parameters)}</p></div></details>
 <div className="auto-welcome-actions"><Link className="dash-button dash-secondary" href={`${base}?tab=welcome&edit=1`}>{template?'Edit message / photo':'Set up welcome message'}</Link><TemplateSync pid={pid} disabled={!connected}/></div>
 <p className="auto-help">Approve the welcome once, then use the switch. It sends once per booking with prior contact permission. Hi, Hello and Menu open the guest menu.</p>
 {changed&&<button name="intent" value="assign" className="dash-button dash-secondary" disabled={pending||!ready}>Use this welcome message</button>}

 {!ready&&<p className="auto-notice">{!connected?'Connect your hotel’s WhatsApp number first.':needsPhoto?'This template needs a delivery photo. Use Edit message / photo, or select its image in Templates.':'Choose an approved utility template with a personal guest link. Use Set up welcome message to create one, then sync approval.'}</p>}
 {on&&!workerReady&&<p className="auto-notice error">Delivery service needs attention. Your welcome is enabled, but delivery cannot be confirmed. <Link href={`${base}?tab=history`}>Check activity →</Link></p>}
 {!menuReady&&<p className="auto-help"><Link href={`${base}?tab=menu`}>Publish your guest menu</Link> to answer Hi, Hello or Menu. Document requirements and guest check-in stay in <Link href={`${base}?tab=journey`}>Guest journey settings</Link>.</p>}
 {state.error&&<p className="auto-notice error" role="alert">{state.error}</p>}{state.success&&<p className="auto-notice" role="status">{state.success}</p>}
 </form></section>;
}

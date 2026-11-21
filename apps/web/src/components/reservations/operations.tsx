"use client";
import { useActionState,useState } from 'react';
import { reservationOperation,type OperationState } from '@/app/p/[propertyId]/reservations/actions';
import type { Detail } from '@/lib/reservations';
export function StayOperations({detail,today,rooms}:{detail:Detail;today:string;rooms:{id:string;name:string;housekeeping_status:string}[]}){
 const [state,action,pending]=useActionState(reservationOperation,{} as OperationState);
 const [notesState,notesAction,notesPending]=useActionState(reservationOperation,{} as OperationState);
 const [operation,setOperation]=useState('');const [notes,setNotes]=useState(detail.stay.notes);
 const r=detail.stay;
 const hidden=<><input type="hidden" name="id" value={r.id}/><input type="hidden" name="pid" value={r.property_id}/><input type="hidden" name="version" value={r.version}/></>;
 const choices=[
  ...(detail.can_frontdesk&&r.status==='confirmed'?[{id:'check_in',label:'Check in guest'}]:[]),
  ...(detail.can_frontdesk&&r.status==='checked_in'?[{id:'check_out',label:'Check out guest'}]:[]),
  ...(detail.can_frontdesk&&['confirmed','checked_in'].includes(r.status)?[{id:'move',label:'Move to another room'}]:[]),
  ...(detail.can_bill&&r.status==='checked_in'?[{id:'post_charges',label:'Post all booked room nights'}]:[]),
  ...(detail.can_write&&r.status==='confirmed'&&r.source!=='ota'?[{id:'cancel',label:'Cancel reservation'}]:[]),
  ...(detail.can_write&&r.status==='confirmed'&&r.check_in<=today?[{id:'no_show',label:'Mark as no-show'}]:[]),
 ];
 return <>
 {choices.length>0&&<section className="res-panel"><h2>Stay actions</h2><form action={action} className="res-form">{hidden}<label>Choose an action<select name="operation" required value={operation} onChange={e=>setOperation(e.target.value)}><option value="">Select an action…</option>{choices.map(c=><option key={c.id} value={c.id}>{c.label}</option>)}</select></label>
 {operation==='check_in'&&<p className="res-action-explainer">Check-in requires an active, clean room and a date within the booked stay. Another guest must not still be checked into the room.</p>}
 {operation==='check_out'&&<p className="res-action-explainer">All booked nights will be charged, including early departures. Settle the final folio balance in Billing before checking out. The room will be marked dirty and a cleaning task created.</p>}
 {operation==='post_charges'&&<p className="res-action-explainer">Posts every booked room night to the folio. Already-posted nights are skipped. No payment is recorded.</p>}
 {operation==='no_show'&&<p className="res-action-explainer">Releases the room allocation and records the no-show. This does not calculate fees or update an external channel.</p>}
 {operation==='move'&&<label>Destination room<select name="unit_id" required><option value="">Choose a different room…</option>{rooms.filter(u=>u.id!==detail.room?.id).map(u=><option key={u.id} value={u.id}>{u.name} · {u.housekeeping_status.replace('_',' ')}</option>)}</select><small>Same room type only. The room must be free for the booked dates. In-house moves require a clean room and create a cleaning task for the previous room.</small></label>}
 {['cancel','no_show','move'].includes(operation)&&<label>Reason<textarea name="reason" required minLength={3} maxLength={500} rows={3} placeholder="Record why this action is needed"/></label>}
 {operation&&<label className="res-confirm-check"><input key={operation} type="checkbox" required/>I confirm this action for {detail.guest.full_name}.</label>}
 {state.error&&<p role="alert" className="res-alert error">{state.error}</p>}
 <button className="dash-button" disabled={pending||!operation}>{pending?'Updating stay…':'Confirm action'}</button></form></section>}
 {detail.can_write&&<section className="res-panel"><h2>Internal notes</h2><form action={notesAction} className="res-form">{hidden}<input type="hidden" name="operation" value="notes"/><label>Notes for your team<textarea name="notes" rows={4} maxLength={2000} value={notes} onChange={e=>setNotes(e.target.value)}/><small>Visible to staff with reservation access. Do not enter payment card details.</small></label>{notesState.error&&<p className="res-alert error" role="alert">{notesState.error}</p>}{notesState.success&&<p className="res-alert success" role="status">{notesState.success}</p>}<button className="dash-button dash-secondary" disabled={notesPending}>{notesPending?'Saving…':'Save notes'}</button></form></section>}
 </>;
}

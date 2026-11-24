'use client';
import {useActionState,useState} from 'react';
import {manageGuestIdentity,type GuestIdentityState} from '@/app/p/[propertyId]/reservations/guests/actions';
export type ManagedGuest={id:string;full_name:string;phone:string|null;email:string|null;bookings:number;active_bookings:number;linked:boolean;can_delete:boolean};
export function GuestIdentityControls({pid,guest:g}:{pid:string;guest:ManagedGuest}){
 const[state,action,pending]=useActionState(manageGuestIdentity,{} as GuestIdentityState),[operation,setOperation]=useState(''),[reason,setReason]=useState(''),[confirmation,setConfirmation]=useState('');
 if(state.success)return <p className="guest-identity-result" role="status">{state.success}</p>;
 return <div className="guest-identity-controls">
  <div className="guest-identity-buttons">{g.linked&&<button type="button" className="dash-button dash-secondary" disabled={pending||g.active_bookings>0} onClick={()=>setOperation(operation==='reset'?'':'reset')}>Reset WhatsApp link</button>}{g.can_delete&&<button type="button" className="dash-button dash-secondary" disabled={pending} onClick={()=>setOperation(operation==='delete'?'':'delete')}>Delete unused profile</button>}</div>
  {g.active_bookings>0&&g.linked&&<p>Resolve {g.active_bookings} confirmed / in-house stay(s) before resetting. <a href={`/p/${pid}/reservations?view=all&q=${encodeURIComponent(g.full_name)}`}>View bookings →</a></p>}
  {!g.can_delete&&<p>Booking or messaging history is kept. This profile cannot be deleted.</p>}
  {operation&&<form action={action} className="guest-identity-confirm">
   <h3>{operation==='reset'?'Reset this guest’s WhatsApp link?':'Delete this unused guest profile?'}</h3>
   <p>{operation==='reset'?'Removes this hotel’s guest-to-number link and messaging permissions, cancels pending messages and disables old private guest links. Bookings, bills, documents and conversation history stay saved. STOP preferences remain in effect.':'Permanently removes this unused profile. The app will check again that it has no linked history.'}</p>
   <input type="hidden" name="pid" value={pid}/><input type="hidden" name="guest" value={g.id}/><input type="hidden" name="phone" value={g.phone??''}/><input type="hidden" name="operation" value={operation}/>
   <label>Reason<textarea name="reason" value={reason} onChange={event=>setReason(event.target.value)} minLength={10} maxLength={1000} rows={2} required placeholder="For example, this number was linked to a test guest by mistake" disabled={pending}/></label>
   <label><span>Type <strong>{g.full_name}</strong> to confirm</span><input name="confirmation" value={confirmation} onChange={event=>setConfirmation(event.target.value)} required autoComplete="off" disabled={pending}/></label>
   {state.error&&<p className="res-alert error" role="alert">{state.error}</p>}
   <div className="guest-identity-buttons"><button className="dash-button" disabled={pending}>{pending?'Saving…':operation==='reset'?'Confirm reset':'Delete profile'}</button><button type="button" className="dash-button dash-secondary" disabled={pending} onClick={()=>setOperation('')}>Cancel</button></div>
  </form>}
 </div>;
}

'use client';
import {useActionState} from 'react';
import {reviewCommand,type ReviewResult} from '@/app/p/[propertyId]/channels/review/actions';
export function ReviewForm({property,caseId,version,request,action,candidates=[]}:{property:string;caseId:string;version:number;request:string;action:'retry'|'link'|'resolve_manual';candidates?:{id:string;label:string}[]}){
 const[state,submit,pending]=useActionState<ReviewResult,FormData>(reviewCommand,{});
 const label=action==='retry'?'Queue retry':action==='link'?'Link matching reservation':'Record manual resolution';
 return <form action={submit} className="channel-review-form">
  <input type="hidden" name="property" value={property}/><input type="hidden" name="case" value={caseId}/><input type="hidden" name="version" value={version}/><input type="hidden" name="request" value={request}/><input type="hidden" name="action" value={action}/>
  {action==='link'&&<label>Matching hotel reservation<select name="reservation" required defaultValue=""><option value="" disabled>Choose the booking you verified</option>{candidates.map(r=><option key={r.id} value={r.id}>{r.label}</option>)}</select></label>}
  <label>{action==='retry'?'What did you fix?':'Resolution / verification notes'}<textarea name="reason" minLength={5} maxLength={1000} rows={3} required placeholder={action==='retry'?'For example: corrected the room mapping.':'Record what you verified and the actions taken in the hotel and provider systems.'}/></label>
  {action!=='retry'&&<label className="channel-confirm"><input name="confirmed" type="checkbox" required/>I checked the provider booking and recorded the required inventory and financial actions. Future changes will be reviewed manually.</label>}
  {state.error&&<p role="alert" className="channel-review-error">{state.error}</p>}{state.message?<p role="status">{state.message}</p>:<button className="dash-button" disabled={pending}>{pending?'Saving…':label}</button>}
 </form>;
}

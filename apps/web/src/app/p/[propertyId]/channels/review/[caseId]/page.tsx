import Link from 'next/link';
import {randomUUID} from 'node:crypto';
import {notFound} from 'next/navigation';
import {createClient} from '@/lib/supabase/server';
import {reviewSnapshot,canLinkSnapshot} from '@/lib/channel-review';
import {ReviewForm} from '@/components/channels/review-form';
import '@/components/service-desk/service-desk.css';
import '../../channels.css';
export const metadata={title:'Review channel booking · Hospitality'};
export default async function ReviewCase({params}:{params:Promise<{propertyId:string;caseId:string}>}){
 const{propertyId:pid,caseId}=await params,db=await createClient();
 const{data:c,error}=await db.from('channel_review_cases').select('*').eq('id',caseId).eq('property_id',pid).maybeSingle();
 if(error)return <p role="alert">This review case could not be loaded. Refresh or ask your hotel administrator for access.</p>;
 if(!c)notFound();
 const[{data:event},{data:actions},{data:linked}]=await Promise.all([
 db.from('channel_events').select('payload,error,status,attempts').eq('id',c.latest_event_id).eq('property_id',pid).single(),
 db.from('channel_review_actions').select('id,action,reason,created_at,actor:profiles(full_name)').eq('case_id',c.id).eq('property_id',pid).order('created_at',{ascending:false}).limit(30),
 c.reservation_id?db.from('reservations').select('id,channel_ref').eq('id',c.reservation_id).eq('property_id',pid).maybeSingle():Promise.resolve({data:null})]);
 if(!event)return <p role="alert">The latest booking snapshot is unavailable. Refresh before taking action.</p>;
 const s=reviewSnapshot(event.payload),linkable=canLinkSnapshot(event.payload);
 const candidates=linkable?(await db.from('reservations').select('id,channel_ref,total_amount,guest:guests(full_name)').eq('property_id',pid).in('status',['confirmed','checked_in']).eq('check_in',s.arrival).eq('check_out',s.departure).eq('adults',s.adults).eq('children',s.children).eq('currency',s.currency).eq('total_amount',s.amount).order('created_at',{ascending:false}).limit(30)).data:[];
 const formProps={property:pid,caseId:c.id,version:c.version};
 return <div className="service-workspace"><Link href={`/p/${pid}/channels/review`}>← Import review</Link><section className="channel-review-panel"><span className="sr-eyebrow">Agoda booking {c.external_reservation_id}</span><h2>{c.status==='resolved'?'Resolution recorded':'Review reservation import'}</h2><p>{c.management_mode==='manual'?'This booking is managed manually. New provider changes will require review.':'Fix mappings or availability before retrying. Compare the provider booking with hotel records before linking.'}</p>
 {event.error&&<p className="channel-notice" role="status">{event.error}</p>}
 <dl className="channel-review-summary">{[['Guest',s.guest||'Not provided'],['Provider status',s.status],['Stay',s.arrival&&s.departure?`${s.arrival} → ${s.departure}`:'Not provided'],['Rooms / guests',`${s.roomCount??'Unknown'} rooms · ${s.adults??'Unknown'} adults · ${s.children??'Unknown'} children`],['Provider room',s.room||'Not provided'],['Amount',s.amount?`${s.amount} ${s.currency}`:'Not available'],['Amount basis',s.basis||'Not available'],['Collection',s.payment||'Not available'],['Revision',s.revision]].map(([label,value])=><div key={label}><dt>{label}</dt><dd>{value||'Not provided'}</dd></div>)}</dl>
 {linked&&<p><Link href={`/p/${pid}/reservations/${linked.id}`}>Open linked hotel reservation →</Link></p>}
 <p className="channel-notice">These actions record local handling only. They do not acknowledge, amend or cancel the booking on Agoda, allocate rooms, or post financial transactions.</p>
 {c.status==='open'&&<div className="channel-review-options">
 {c.management_mode==='automatic'&&<article><h3>Retry a corrected import</h3><p>Use after fixing room mappings or inventory. Unsupported settlement and group bookings still need manual handling.</p><ReviewForm key={`retry-${c.version}`} {...formProps} request={randomUUID()} action="retry"/></article>}
 {linkable&&<article><h3>Link a reservation already recorded</h3><p>Choose the verified matching booking. The server also checks held room type and existing channel links. Financial amounts stay unchanged.</p>{candidates?.length?<ReviewForm key={`link-${c.version}`} {...formProps} request={randomUUID()} action="link" candidates={candidates.map((r:any)=>({id:r.id,label:`${Array.isArray(r.guest)?r.guest[0]?.full_name:r.guest?.full_name} · ${r.channel_ref||r.id.slice(0,8)} · ${r.total_amount} ${s.currency}`}))}/>:<p>No matching reservations are available. Check the provider details and record the hotel booking correctly first.</p>}</article>}
 <article><h3>Resolve with manual handling</h3><p>Use after you have handled the booking in the provider and hotel systems. Record group reservations, settlement decisions, or inventory resolution in the notes. Later provider changes reopen the case.</p><ReviewForm key={`manual-${c.version}`} {...formProps} request={randomUUID()} action="resolve_manual"/></article>
 </div>}
 <h3>Review history</h3>{actions?.length?<ol className="channel-review-history">{actions.map(a=><li key={a.id}><strong>{a.action.replaceAll('_',' ')}</strong><time>{new Date(a.created_at).toLocaleString('en-IN',{timeZone:'Asia/Kolkata'})} IST</time><small>By {Array.isArray(a.actor)?a.actor[0]?.full_name||'Hotel staff':(a.actor as {full_name?:string}|null)?.full_name||'Hotel staff'}</small><p>{a.reason}</p></li>)}</ol>:<p>No staff review actions recorded yet.</p>}
 </section></div>;
}

import Link from 'next/link';
import {createClient} from '@/lib/supabase/server';
import {reviewPage} from '@/lib/channel-review';
import '@/components/service-desk/service-desk.css';
import '../channels.css';
export const metadata={title:'Channel import review · Hospitality'};
export default async function ReviewQueue({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{page?:string;status?:string}>}){
 const{propertyId:pid}=await params,filters=await searchParams,page=reviewPage(filters.page),status=filters.status==='resolved'?'resolved':'open',db=await createClient();
 const{data,error,count}=await db.from('channel_review_cases').select('id,external_reservation_id,status,management_mode,updated_at',{count:'exact'}).eq('property_id',pid).eq('status',status).order('updated_at',{ascending:false}).order('id').range((page-1)*20,page*20-1);
 const base=`/p/${pid}/channels/review`;
 return <div className="service-workspace"><Link href={`/p/${pid}/channels`}>← Channels</Link><section className="channel-review-panel"><span className="sr-eyebrow">Reservation exceptions</span><h2>Import review</h2><p>Investigate failed Agoda snapshots, retry corrected imports, or record a verified manual resolution.</p>
 <nav className="channel-review-tabs" aria-label="Review status"><Link aria-current={status==='open'?'page':undefined} href={base}>Open cases</Link><Link aria-current={status==='resolved'?'page':undefined} href={`${base}?status=resolved`}>Resolved cases</Link></nav>
 {error?<p role="alert">The review queue could not be loaded. Refresh or ask your hotel administrator for channel management access.</p>:<><div className="sr-table-scroll"><table className="sr-table"><thead><tr><th>Agoda booking</th><th>Handling</th><th>Updated</th><th>Review</th></tr></thead><tbody>{data?.map(c=><tr key={c.id}><td>{c.external_reservation_id}</td><td>{c.management_mode==='manual'?'Manual handling':'Automatic import'}</td><td>{new Date(c.updated_at).toLocaleString('en-IN',{timeZone:'Asia/Kolkata'})} IST</td><td><Link href={`${base}/${c.id}`}>Review case →</Link></td></tr>)}</tbody></table></div>{!data?.length&&<p className="sr-empty">No {status} cases.</p>}
 <div className="sr-pagination"><span>{count??0} {status} cases · Page {page}</span><div>{page>1&&<Link href={`${base}?status=${status}&page=${page-1}`}>← Previous</Link>}{page*20<(count??0)&&<Link href={`${base}?status=${status}&page=${page+1}`}>Next →</Link>}</div></div></>}
 </section></div>;
}

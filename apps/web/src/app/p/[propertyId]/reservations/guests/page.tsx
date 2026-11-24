import Link from 'next/link';
import {createClient} from '@/lib/supabase/server';
import {GuestIdentityControls,type ManagedGuest} from '@/components/reservations/guest-identity-controls';
import '@/components/reservations/reservations.css';
import './guests.css';
export const metadata={title:'Manage guests · Hospitality'};
export default async function ManageGuests({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{q?:string;page?:string}>}){
 const {propertyId:pid}=await params,input=await searchParams,q=(input.q??'').trim().slice(0,100),page=Math.max(1,Math.min(10000,Number.parseInt(input.page??'1',10)||1)),db=await createClient();
 const {data,error}=await db.rpc('guest_identity_workspace',{p_property:pid,p_query:q,p_page:page});
 if(error)return <section className="res-empty"><h1>Manage guests</h1><h2>{error.code==='42501'?'Administrator access required':'Couldn’t load guest profiles'}</h2><p>{error.code==='42501'?'Ask your hotel administrator to review guest profiles.':'Refresh and try again. No guest records have been changed.'}</p><Link href={`/p/${pid}/reservations`}>Back to reservations →</Link></section>;
 const guests=data.rows as ManagedGuest[],pages=Math.max(1,Math.ceil(data.total/20)),href=(n:number)=>`?${new URLSearchParams({q,page:String(n)})}`;
 return <div className="guest-identity-page">
  <header className="guest-directory-heading"><div><Link href={`/p/${pid}/reservations`}>← Reservations</Link><h1>Manage guests</h1><p>Find a guest, review their profile or book their next stay.</p></div><Link className="dash-button" href={`/p/${pid}/reservations/new`}>＋ New reservation</Link></header>
  <section className="guest-directory" aria-label="Guest profiles"><form method="get" className="guest-identity-search"><label>Find a guest<input name="q" type="search" defaultValue={q} maxLength={100} placeholder="Name, phone or email"/></label><button className="dash-button">Search</button>{q&&<Link href={`?q=`}>Clear</Link>}</form><div className="guest-directory-caption"><span>{data.total} {data.total===1?'guest':'guests'}{q?' matching your search':''}</span><span>Open a profile to see details and actions.</span></div>
   <div className="guest-identity-list">{guests.map(g=><details key={g.id} className="guest-profile" name="guest-profile"><summary className="guest-row-summary"><span className="guest-avatar" aria-hidden="true">{g.full_name.split(/\s+/).filter(Boolean).slice(0,2).map(n=>n[0]).join('').toUpperCase()}</span><span className="guest-row-name"><strong>{g.full_name}</strong><small>{g.phone||g.email||'No contact recorded'}</small></span><span className="guest-row-bookings">{g.bookings} {g.bookings===1?'booking':'bookings'}{g.active_bookings>0&&<small>{g.active_bookings} active</small>}</span><span className={`guest-link-badge ${g.linked?'linked':''}`}>{g.linked?'WhatsApp linked':'Not linked'}</span><span className="guest-chevron" aria-hidden="true">⌄</span></summary>
    <div className="guest-profile-content"><div className="guest-profile-contact"><div><span>Phone</span><strong>{g.phone||'Not provided'}</strong></div><div><span>Email</span><strong>{g.email||'Not provided'}</strong></div></div>
     {g.bookings>0&&<div className="guest-profile-actions"><Link className="dash-button" href={`/p/${pid}/reservations/new?guest=${g.id}`}>Book a stay →</Link><Link className="dash-button dash-secondary" href={`/p/${pid}/reservations?view=all&q=${encodeURIComponent(g.full_name)}`}>Search bookings →</Link></div>}
     <details className="guest-maintenance"><summary>WhatsApp link & profile controls</summary><GuestIdentityControls pid={pid} guest={g}/></details>
    </div>
   </details>)}</div>
   {!guests.length&&<div className="guest-directory-empty"><h2>{q?'No guests found':'No guest profiles yet'}</h2><p>{q?'Try a different name, phone or email.':'Guest profiles appear when you create reservations.'}</p><Link className="dash-button dash-secondary" href={q?'?q=':`/p/${pid}/reservations/new`}>{q?'Clear search':'Create a reservation →'}</Link></div>}
   <nav className="guest-identity-pagination" aria-label="Guest pages"><span>{data.total?`${(page-1)*20+1}–${Math.min(page*20,data.total)} of ${data.total} guests`:'0 guests'}</span><div>{page>1&&<Link href={href(page-1)}>← Previous</Link>}<span>Page {page} of {pages}</span>{page*20<data.total&&<Link href={href(page+1)}>Next →</Link>}</div></nav>
  </section>
  <details className="guest-directory-help"><summary>About guest profiles and WhatsApp links</summary><p>Returning bookings reuse the selected guest’s history and messaging preferences. A matching phone number does not merge profiles automatically.</p><p>Resetting a WhatsApp link requires resolved stays and a recorded reason. Booking, billing and conversation history is preserved. Only unused profiles can be deleted.</p></details>
 </div>;
}

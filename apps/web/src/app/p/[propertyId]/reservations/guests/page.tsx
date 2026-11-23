import Link from 'next/link';
import {createClient} from '@/lib/supabase/server';
import {GuestIdentityControls,type ManagedGuest} from '@/components/reservations/guest-identity-controls';
import '@/components/reservations/reservations.css';
import './guests.css';
export const metadata={title:'Manage guests · Hospitality'};
export default async function ManageGuests({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{q?:string;page?:string}>}){
 const{propertyId:pid}=await params,input=await searchParams,q=(input.q??'').trim().slice(0,100),page=Math.max(1,Math.min(10000,Number.parseInt(input.page??'1',10)||1)),db=await createClient();
 const{data,error}=await db.rpc('guest_identity_workspace',{p_property:pid,p_query:q,p_page:page});
 if(error)return <section className="res-empty"><h2>{error.code==='42501'?'Administrator access required':'Couldn’t load guest profiles'}</h2><p>{error.code==='42501'?'Ask your hotel administrator to review the guest’s WhatsApp link.':'Refresh and try again. No guest records have been changed.'}</p><Link href={`/p/${pid}/reservations`}>Back to reservations →</Link></section>;
 const guests=data.rows as ManagedGuest[],href=(n:number)=>`?${new URLSearchParams({q,page:String(n)})}`;
 return <div className="guest-identity-page"><header><Link href={`/p/${pid}/reservations`}>← Reservations</Link><h2>Manage guests</h2><p>Correct an old WhatsApp link or remove an unused profile.</p></header>
  <form method="get" className="guest-identity-search"><label>Find a guest<input name="q" defaultValue={q} maxLength={100} placeholder="Name, phone or email"/></label><button className="dash-button">Search</button>{q&&<Link href="?">Clear</Link>}</form>
  <div className="guest-identity-list">{guests.map(g=><article key={g.id} className="res-panel"><div className="guest-identity-heading"><div><h3>{g.full_name}</h3><p>{g.phone||'No phone'}{g.email?` · ${g.email}`:''}</p></div><span>{g.linked?'WhatsApp linked':'No WhatsApp link'}</span></div><p>{g.bookings} booking(s) at this hotel · {g.active_bookings} active</p><GuestIdentityControls pid={pid} guest={g}/></article>)}</div>
  {!guests.length&&<p className="res-empty">No guest profiles match this search.</p>}
  <nav className="guest-identity-pagination" aria-label="Guest pages"><span>{data.total} guest profiles · Page {page}</span><div>{page>1&&<Link href={href(page-1)}>← Previous</Link>}{page*20<data.total&&<Link href={href(page+1)}>Next →</Link>}</div></nav>
 </div>;
}

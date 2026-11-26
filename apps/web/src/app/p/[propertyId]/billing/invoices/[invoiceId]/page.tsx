
import {displayDateTime} from '@/lib/date-format';
import Link from 'next/link';
import {notFound} from 'next/navigation';
import {createClient} from '@/lib/supabase/server';
import {validId,money,dayLabel} from '@/lib/reservations';
import {type InvoiceData} from '@/lib/billing';
import {PrintDocument} from '@/components/billing/forms';
import '@/components/billing/billing.css';
export const metadata={title:'Invoice document · Hospitality'};
export default async function InvoicePage({params,searchParams}:{params:Promise<{propertyId:string;invoiceId:string}>;searchParams:Promise<{credit?:string}>}){
 const {propertyId:pid,invoiceId:id}=await params,{credit}=await searchParams;if(!validId(pid)||!validId(id))notFound();
 const db=await createClient();const {data,error}=await db.rpc('billing_invoice',{p_property:pid,p_invoice:id});
 if(error?.code==='P0002')notFound();if(error||!data)return <section className="bill-empty"><h2>Invoice unavailable</h2><p>Check your billing permissions and try again.</p></section>;
 const d=data as InvoiceData,s=d.snapshot,c=credit?d.credits.find(c=>c.id===credit):undefined;if(credit&&!c)notFound();
 const issued=c?.issued_at??d.issued_at;
 return <div className="billing-workspace bill-document-workspace"><div className="bill-document-toolbar"><Link href={`/p/${pid}/billing/${d.reservation_id}`}>← Back to guest folio</Link><PrintDocument/></div>
 <article className="invoice-document"><header><div className="invoice-brand"><span>h·</span><div><h2>{s.property.name}</h2><p>{[s.property.address,s.property.city,s.property.country_code].filter(Boolean).join(', ')}</p><p>{[s.property.email,s.property.phone].filter(Boolean).join(' · ')}</p></div></div><div className="invoice-number"><span>{c?'CREDIT NOTE':'INVOICE'}</span><h1>{c?.number??d.number}</h1><p>{displayDateTime(new Date(issued),s.property.timezone??'UTC').split(' · ')[0]}</p></div></header>
 <div className="invoice-parties"><div><span>ISSUED TO</span><strong>{s.guest.name}</strong><p>{s.guest.email}</p><p>{s.guest.phone}</p></div><div><span>STAY DETAILS</span><strong>{dayLabel(s.stay.check_in)} → {dayLabel(s.stay.check_out)}</strong><p>Booking {s.stay.id.slice(0,8).toUpperCase()}</p>{c&&<p>Against invoice {d.number}</p>}</div></div>
 {s.legacy_snapshot&&<p className="invoice-legacy">Legacy invoice: an original identity snapshot was not captured. Hotel and guest details shown reflect the current records.</p>}
 <div className="invoice-table-wrap"><table><thead><tr><th>Description</th><th>{c?'Reference':'Business date'}</th><th>Amount ({s.currency})</th></tr></thead><tbody>{c?<tr><td>{c.reason}</td><td>{d.number}</td><td>{money(c.amount,s.currency)}</td></tr>:s.items.map((item,i)=><tr key={i}><td>{item.description}<small>{item.kind==='room'?'Accommodation':item.kind==='order'?'Recorded room order':'Adjustment'}</small></td><td>{dayLabel(item.date)}</td><td>{money(item.amount,s.currency)}</td></tr>)}</tbody></table></div>
 <div className="invoice-totals"><div><span>{c?'Credit note total':'Invoice total'}</span><strong>{money(c?.amount??s.total,s.currency)}</strong></div>{!c&&s.payments!==undefined&&<><div><span>Payments at issue</span><b>{money(s.payments,s.currency)}</b></div><div><span>Refunds before issue</span><b>{money(s.refunds??0,s.currency)}</b></div><div className="invoice-settled"><span>Balance at issue</span><b>{money(0,s.currency)}</b></div></>}</div>
 <footer><strong>{c?'Credit linked to a recorded refund.':'Thank you for staying with us.'}</strong><p>{c?'This credit note reduces the original invoice amount. The refund is recorded separately in the guest folio.':'This document reflects the posted ledger at issue. Later credit notes and refunds are separate records.'}</p><p>Order charges include their recorded tax. No additional accommodation tax is calculated by this document.</p></footer>
 </article>
 {!c&&d.credits.length>0&&<section className="bill-panel bill-document-related"><h2>Related credit notes</h2>{d.credits.map(c=><Link key={c.id} href={`?credit=${c.id}`}>{c.number} · {money(c.amount,s.currency)} ↗</Link>)}</section>}
 {c&&<Link className="bill-document-original" href={`/p/${pid}/billing/invoices/${id}`}>View original invoice →</Link>}
 </div>;
}

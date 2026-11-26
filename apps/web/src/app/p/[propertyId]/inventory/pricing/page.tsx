
import {displayDateTime} from '@/lib/date-format';
import {DateInput} from '@/components/date-input';
import Link from'next/link';
import{randomUUID}from'node:crypto';
import{createClient}from'@/lib/supabase/server';
import{validId,dayLabel,money}from'@/lib/reservations';
import{pricingStart,addPricingDays,type RoomPricingWorkspace}from'@/lib/room-pricing';
import{DatePricing}from'@/components/inventory/date-pricing';
import'@/components/inventory/date-pricing.css';
export const metadata={title:'Date pricing · Hospitality'};
export default async function RoomPricingPage({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<Record<string,string|undefined>>}){
 const{propertyId:pid}=await params,p=await searchParams,type=validId(p.type)?p.type:null,page=/^\d+$/.test(p.page??'')?Math.min(100000,Math.max(1,Number(p.page))):1,db=await createClient();
 const{data,error}=await db.rpc('room_pricing_workspace',{p_property:pid,p_start:pricingStart(p.start)??null,p_type:type,p_page:page});
 if(error||!data)return <section><h1>Date pricing unavailable</h1><p>Check your inventory management access or refresh the calendar.</p><Link href={`/p/${pid}/inventory?mode=types`}>Back to room types →</Link></section>;
 const s=data as RoomPricingWorkspace,base=`/p/${pid}/inventory/pricing`,href=(start:string,pg=1)=>base+'?'+new URLSearchParams({start,page:String(pg),...(type?{type}: {})});
 const calendarTools=<section className="pricing-view"><form><label>Calendar starts<DateInput name="start" required defaultValue={s.start} min="2000-01-01" max={s.latest}/></label><label>Show room type<select name="type" defaultValue={type??''}><option value="">All room types</option>{s.types.map(t=><option key={t.id} value={t.id}>{t.name}</option>)}</select></label><button className="dash-button dash-secondary">View dates</button></form><nav aria-label="Calendar dates">{s.start>'2000-01-14'&&<Link href={href(addPricingDays(s.start,-14))}>← Previous 14 nights</Link>}<Link href={href(s.day)}>Today</Link>{addPricingDays(s.start,14)<=s.latest&&<Link href={href(addPricingDays(s.start,14))}>Next 14 nights →</Link>}</nav><p>{dayLabel(s.start)} – {dayLabel(addPricingDays(s.start,13))} · {s.timezone} · {s.currency}</p></section>;
 return <div className="date-pricing-page"><header className="pricing-heading"><div><Link href={`/p/${pid}/inventory?mode=types`}>← Rooms & inventory</Link><h1>Room prices by date</h1><p>Different prices for weekdays, weekends, holidays and selected weeks.</p></div></header>
 <nav className="pricing-nav" aria-label="Pricing setup"><Link href={`/p/${pid}/inventory?mode=types`}>Room types</Link><Link href={base} aria-current="page">Date pricing</Link><Link href={`/p/${pid}/inventory?mode=rates`}>Rate plans</Link></nav>
 {p.saved&&/^\d+$/.test(p.saved)&&<p className="pricing-success" role="status">{p.saved} selected nights {p.operation==='reset'?'restored to the current base price':'updated'}. Existing bookings were not changed.</p>}
 {!s.types.length?<section className="pricing-card"><h2>Add a room type first</h2><p>Set its base nightly price, then add special prices for specific dates.</p><Link className="dash-button" href={`/p/${pid}/inventory/types/new`}>Add room type</Link></section>:<>
 <DatePricing key={`${s.version}:${s.start}:${type??'all'}:${page}`} pid={pid} data={s} request={randomUUID()} initialType={type??undefined} calendarTools={calendarTools}/>

 {s.total>10&&<nav className="pricing-pages" aria-label="Room type pages"><span>{s.total} room types · page {s.page}</span><div>{s.page>1&&<Link href={href(s.start,s.page-1)}>← Previous types</Link>}{s.page*10<s.total&&<Link href={href(s.start,s.page+1)}>More room types →</Link>}</div></nav>}
 <p className="pricing-footnote">Prices are per room per night. The last selected night is included; checkout is the following day. Set up to 366 nights per update, up to two years ahead. These prices apply to new bookings made in Hospitality; external channel prices are not updated here.</p>
 {s.history.length>0&&<details className="pricing-history"><summary>Recent price changes</summary><ul>{s.history.map((h,i)=><li key={h.created_at+i}><strong>{s.types.find(t=>t.id===h.payload.type)?.name??'Room type'} · {h.result.nights} nights</strong><p>{dayLabel(h.payload.from)} – {dayLabel(h.payload.to)} · {h.payload.reset?'Base price restored':money(h.payload.amount??0,s.currency)+' per night'}{h.payload.label?' · '+h.payload.label:''}</p><small>{h.actor_name??'Staff'} · {displayDateTime(new Date(h.created_at),s.timezone)}</small></li>)}</ul></details>}
 </>}
 </div>;
}

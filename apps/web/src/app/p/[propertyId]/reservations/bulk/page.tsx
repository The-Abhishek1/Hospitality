import {DateInput} from '@/components/date-input';
import Link from 'next/link';
import {randomUUID}from'node:crypto';
import {createClient}from'@/lib/supabase/server';
import {todayIn}from'@/lib/dates';
import {validDay,type ReservationWorkspace}from'@/lib/reservations';
import {BulkStays}from'@/components/reservations/bulk-stays';
import '@/components/reservations/reservations.css';
import '@/components/reservations/frontdesk-tools.css';
export const metadata={title:'Group check-in & checkout · Hospitality'};
export default async function BulkPage({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<Record<string,string|undefined>>}){
 const{propertyId:pid}=await params,input=await searchParams,db=await createClient(),operation=input.action==='check_out'?'check_out':'check_in',q=(input.q??'').trim().slice(0,100),day=validDay(input.day)?input.day:'',page=Math.max(1,Math.min(100000,Number.parseInt(input.page??'1',10)||1));
 const{data:property}=await db.from('properties').select('timezone').eq('id',pid).single(),today=todayIn(property?.timezone??'Asia/Kolkata');
 const{data,error}=await db.rpc('reservation_workspace',{p_property:pid,p_filters:{view:operation==='check_in'?'all':'in_house',status:operation==='check_in'?'confirmed':'checked_in',q,page,mode:'list',from:day||(operation==='check_in'?today:''),to:day||(operation==='check_in'?today:'')}});
 if(error||!data?.can_frontdesk)return <section className="res-empty"><h1>Group check-in & checkout</h1><p>Front desk and reservation access are required. Ask your administrator or refresh to try again.</p><Link href={`/p/${pid}/reservations`}>Back to reservations →</Link></section>;
 const s=data as ReservationWorkspace,base=`/p/${pid}/reservations/bulk`,href=(changes:Record<string,string|number>)=>`${base}?${new URLSearchParams({action:operation,q,day,page:String(page),...Object.fromEntries(Object.entries(changes).map(([k,v])=>[k,String(v)]))})}`;
 const request=randomUUID();
 return <div className="bulk-page"><header className="bulk-page-header"><Link href={`/p/${pid}/reservations`}>← Reservations</Link><h1>Group check-in & checkout</h1><p>Select the group’s room bookings, review them, then confirm together.</p></header><nav className="bulk-tabs" aria-label="Group action"><Link aria-current={operation==='check_in'?'page':undefined} href={href({action:'check_in',page:1})}>Check in guests</Link><Link aria-current={operation==='check_out'?'page':undefined} href={href({action:'check_out',page:1})}>Check out guests</Link></nav><form method="get" className="bulk-filters"><input type="hidden" name="action" value={operation}/><label>Find guests or bookings<input type="search" name="q" defaultValue={q} maxLength={100} placeholder="Name, phone, email or booking ID"/></label><label>Stay overlaps date<DateInput name="day" defaultValue={day}/></label><button className="dash-button">Search</button>{(q||day)&&<Link href={`${base}?action=${operation}`}>Clear</Link>}</form><p>{operation==='check_in'?'Showing confirmed stays overlapping the selected date or today. Admission checks run separately for every room.':'Showing in-house stays. Guests leaving early are still charged for all booked nights.'} Selection applies to this page.</p><BulkStays key={`${operation}:${q}:${day}:${page}`} pid={pid} request={request} rows={s.rows} operation={operation}/><nav className="bulk-pagination" aria-label="Group booking pages"><span>{s.total} matching stays</span><div>{s.page>1&&<Link href={href({page:s.page-1})}>← Previous</Link>}<span>Page {s.page} of {Math.max(1,Math.ceil(s.total/20))}</span>{s.page*20<s.total&&<Link href={href({page:s.page+1})}>Next →</Link>}</div></nav></div>;
}

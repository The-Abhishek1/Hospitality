import {createClient} from '@/lib/supabase/server';
import {StaffWorkspace,type StaffData} from '@/components/staff/workspace';
import {validDay} from '@/lib/reservations';
import './staff.css';
export default async function StaffPage({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<Record<string,string|undefined>>}){
 const {propertyId:pid}=await params,p=await searchParams,db=await createClient();
 const {data:prop}=await db.from('properties').select('timezone,currency').eq('id',pid).single();
 const month=p.month&&/^\d{4}-\d{2}$/.test(p.month)?p.month:new Intl.DateTimeFormat('en-CA',{timeZone:prop?.timezone??'Asia/Kolkata',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date()).slice(0,7);
 if(!validDay(month+'-01'))return <p role="alert">Choose a valid month.</p>;
 const {data,error}=await db.rpc('staff_workspace',{p_property:pid,p_month:month+'-01',p_query:p.q??'',p_page:Number(p.page)||1});
 if(error)return <p role="alert">Staff attendance and salary records require hotel staff manager access.</p>;
 return <StaffWorkspace key={`${month}:${p.q??''}:${p.page??1}`} pid={pid} data={data as StaffData} currency={prop?.currency??'INR'} query={p.q??''}/>;
}

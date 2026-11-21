import Link from 'next/link';
import {randomUUID} from 'node:crypto';
import {createClient} from '@/lib/supabase/server';
import {validId} from '@/lib/reservations';
import {type RequestSetup} from '@/lib/service-desk';
import {NewRequestForm} from '@/components/service-desk/new-request-form';
import '@/components/service-desk/service-desk.css';
export const metadata={title:'New guest request · Hospitality'};
export default async function NewRequestPage({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{stay?:string;service?:string}>}){
 const{propertyId:pid}=await params,p=await searchParams,db=await createClient();
 const{data,error}=await db.rpc('service_request_setup',{p_property:pid,p_query:'',p_reservation:validId(p.stay)?p.stay:null});
 if(error)return <section className="sr-empty"><h2>Request management required</h2><p>Ask your administrator for guest-request management access.</p><Link href={`/p/${pid}/requests`}>Back to requests</Link></section>;
 const setup=data as RequestSetup;
 return <div className="service-workspace"><div className="sr-subheading"><div><Link href={`/p/${pid}/requests`}>← Guest request queue</Link><h2>New guest request</h2><p>Choose the guest, describe the need, and let the configured route handle the work.</p></div></div><NewRequestForm pid={pid} request={randomUUID()} initial={setup} initialService={setup.services.some(s=>s.id===p.service)?p.service:undefined}/></div>;
}

import Link from 'next/link';
import {randomUUID} from 'node:crypto';
import {createClient} from '@/lib/supabase/server';
import {CatalogForm} from '@/components/service-desk/catalog-form';
import {type CatalogSetup} from '@/lib/service-desk';
import '@/components/service-desk/service-desk.css';
export default async function NewServicePage({params}:{params:Promise<{propertyId:string}>}){
 const{propertyId:pid}=await params,db=await createClient(),{data,error}=await db.rpc('service_catalog_setup',{p_property:pid});
 if(error)return <section><h2>Service configuration requires management access</h2><Link href={`/p/${pid}/requests`}>Back to requests</Link></section>;
 return <div className="service-workspace"><div className="sr-subheading"><div><Link href={`/p/${pid}/requests/catalog`}>← Service catalog</Link><h2>Add a hotel service</h2><p>Set the priority, response target, and team routing for new requests.</p></div></div><CatalogForm pid={pid} setup={data as CatalogSetup} request={randomUUID()}/></div>;
}

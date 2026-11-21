import Link from 'next/link';
import {randomUUID} from 'node:crypto';
import {notFound} from 'next/navigation';
import {createClient} from '@/lib/supabase/server';
import {CatalogForm} from '@/components/service-desk/catalog-form';
import {type CatalogSetup} from '@/lib/service-desk';
import '@/components/service-desk/service-desk.css';
export default async function EditServicePage({params}:{params:Promise<{propertyId:string;catalogId:string}>}){
 const{propertyId:pid,catalogId}=await params,db=await createClient(),{data,error}=await db.rpc('service_catalog_setup',{p_property:pid});
 if(error)return <section><h2>Service configuration requires management access</h2><Link href={`/p/${pid}/requests`}>Back to requests</Link></section>;
 const setup=data as CatalogSetup,item=setup.services.find(s=>s.id===catalogId);if(!item)notFound();
 return <div className="service-workspace"><div className="sr-subheading"><div><Link href={`/p/${pid}/requests/catalog`}>← Service catalog</Link><h2>Configure {item.name}</h2><p>Existing request history and work assignments are preserved.</p></div></div><CatalogForm pid={pid} item={item} setup={setup} request={randomUUID()}/></div>;
}

import Link from 'next/link';
import {createClient} from '@/lib/supabase/server';
import {MenuImport} from '@/components/orders/menu-import';
import '@/components/service-desk/service-desk.css';
import '@/components/orders/orders.css';
import './import.css';
export const metadata={title:'Import food menu · Hospitality'};
export default async function ImportMenu({params}:{params:Promise<{propertyId:string}>}){
 const{propertyId:pid}=await params,db=await createClient();
 const[{data,error},{data:property}]=await Promise.all([db.rpc('food_menu_access',{p_property:pid}),db.from('properties').select('currency').eq('id',pid).single()]);
 if(error||!data)return <section><h2>Menu management access required</h2><Link href={`/p/${pid}/orders/menu`}>Back to food menu</Link></section>;
 return <div className="service-workspace order-workspace food-workspace"><div className="sr-subheading"><div><Link href={`/p/${pid}/orders/menu`}>← Food menu</Link><h2>Import your food menu</h2><p>Add many dishes at once using Excel or CSV.</p></div></div><MenuImport pid={pid} currency={property?.currency??'INR'}/></div>;
}

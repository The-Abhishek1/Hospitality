import Link from 'next/link';import{randomUUID}from 'node:crypto';import{createClient}from '@/lib/supabase/server';import{validId}from '@/lib/reservations';import{type OrderSetup}from '@/lib/orders';import{OrderComposer}from '@/components/orders/order-composer';import '@/components/service-desk/service-desk.css';import '@/components/orders/orders.css';
export const metadata={title:'New order · Hospitality'};
export default async function NewOrderPage({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{stay?:string}>}){
 const{propertyId:pid}=await params,p=await searchParams,db=await createClient(),{data,error}=await db.rpc('order_setup',{p_property:pid,p_query:'',p_reservation:validId(p.stay)?p.stay:null});
 if(error)return <section><h2>Order placement access required</h2><p>Ask your hotel administrator for permission to place orders.</p><Link href={`/p/${pid}/orders`}>Back to orders</Link></section>;
 return <div className="service-workspace order-workspace"><div className="sr-subheading"><div><Link href={`/p/${pid}/orders`}>← Orders & room service</Link><h2>Good food. Thoughtful service.</h2><p>Choose the destination, build the cart, and share clear preparation instructions.</p></div></div><OrderComposer pid={pid} initial={data as OrderSetup} request={randomUUID()}/></div>;
}

import Link from'next/link';import{randomUUID}from'node:crypto';import{notFound}from'next/navigation';import{createClient}from'@/lib/supabase/server';import{type OrderMenuItem}from'@/lib/orders';import{OrderMenuForm,MenuItemLifecycle}from'@/components/orders/menu-form';import'@/components/service-desk/service-desk.css';import'@/components/orders/orders.css';
export default async function MenuItemPage({params}:{params:Promise<{propertyId:string;itemId:string}>}){
 const{propertyId:pid,itemId}=await params;if(itemId!=='new'&&!/^[a-f0-9-]{36}$/i.test(itemId))notFound();
 const db=await createClient(),{data:s,error}=await db.rpc('food_menu_item',{p_property:pid,p_id:itemId==='new'?null:itemId});
 if(error)return <section><h2>Menu management access required</h2><Link href={`/p/${pid}/orders`}>Back to orders</Link></section>;
 const item=(s.item??undefined)as OrderMenuItem|undefined;if(itemId!=='new'&&!item)notFound();
 return <div className="service-workspace order-workspace food-workspace"><div className="sr-subheading"><div><Link href={`/p/${pid}/orders/menu`}>← Food menu</Link><h2>{item?item.name:'Add a menu item'}</h2><p>Item details → service destinations → prices and sizes.</p></div></div>{!item?.deleted_at&&<OrderMenuForm key={item?.version??'new'} pid={pid} item={item} setup={{currency:s.currency,categories:s.categories,items:[]}} request={randomUUID()}/>} {item&&<MenuItemLifecycle pid={pid} item={item} request={randomUUID()}/>}</div>;
}

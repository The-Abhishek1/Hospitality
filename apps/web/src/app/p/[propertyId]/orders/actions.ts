"use server";
import{redirect}from 'next/navigation';import{revalidatePath}from 'next/cache';import{createClient}from '@/lib/supabase/server';import{validId}from '@/lib/reservations';import{inventoryMoney}from '@/lib/inventory';import{parseAmount,paymentMethods}from '@/lib/billing';import{type OrderSetup,type OrderStay}from '@/lib/orders';
import{foodTypes,foodServices,foodSizePayload}from'@/lib/food-menu';
export type OrderState={error?:string;fields?:Record<string,string>;selected?:OrderStay|null};
export type OrderSearchState={error?:string;data?:OrderSetup;query?:string};
const f=(fd:FormData,k:string)=>String(fd.get(k)??'').trim();
const snapshot=(fd:FormData)=>Object.fromEntries([...fd.entries()].filter(([k])=>!['pid','request','id','version'].includes(k)).map(([k,v])=>[k,String(v).slice(0,2000)]));
const message=(e:{code?:string;message:string})=>e.code==='42501'?'Your role does not allow this action. Kitchen, menu and financial actions require separate access.':e.code==='40001'?'The order, menu, or payment availability changed. Refresh and review the current details.':e.code==='23505'?'This item or action is already recorded. Refresh before trying again.':['22023','P0002'].includes(e.code??'')?e.message:'Couldn’t save these details. Check them and try again.';
const refresh=(pid:string)=>{revalidatePath(`/p/${pid}/orders`,'layout');revalidatePath(`/p/${pid}/billing`,'layout');revalidatePath('/dashboard');};
export async function findOrderStays(_:OrderSearchState,fd:FormData):Promise<OrderSearchState>{const pid=f(fd,'pid'),selected=f(fd,'selected'),query=f(fd,'query').slice(0,100);if(!validId(pid)||selected&&!validId(selected))return{error:'Choose a valid hotel and stay.'};const db=await createClient(),{data,error}=await db.rpc('order_setup',{p_property:pid,p_query:query,p_reservation:selected||null});return error?{error:message(error),query}:{data:data as OrderSetup,query};}
export async function createOrder(_:OrderState,fd:FormData):Promise<OrderState>{
 const pid=f(fd,'pid'),request=f(fd,'request'),fields=snapshot(fd),reservation=f(fd,'reservation_id'),kind=f(fd,'kind'),db=await createClient();
 const fail=async(error:string):Promise<OrderState>=>{let selected:OrderStay|null=null;if(validId(pid)&&validId(reservation)){const{data}=await db.rpc('order_setup',{p_property:pid,p_reservation:reservation,p_query:''});selected=data?.selected??null;}return{error,fields,selected};};
 if(!/^[A-Z]{3}$/.test(f(fd,'currency')))return fail('Review the order currency before submitting.');
 if(!validId(pid)||!validId(request)||!['room_service','restaurant'].includes(kind)||reservation&&!validId(reservation)||kind==='room_service'&&!reservation)return fail('Choose an in-house stay for room service.');
 if(f(fd,'table').length>40||f(fd,'notes').length>2000||!['normal','high','urgent'].includes(f(fd,'priority')))return fail('Check the priority, table label (up to 40 characters), and instructions (up to 2000).');
 const target=f(fd,'target_minutes');if(target&&(!/^\d{1,4}$/.test(target)||Number(target)<1||Number(target)>1440))return fail('Use a response target of 1–1440 whole minutes, or leave it blank.');
 const items:{menu_item_id:string;quantity:number;version:number;variant_id?:string;variant_version?:number}[]=[];for(const[k,v]of fd.entries())if(k.startsWith('qty_')&&String(v).trim()!==''&&String(v)!=='0'){const id=k.slice(4),qty=String(v);if(!validId(id)||!/^\d{1,2}$/.test(qty)||Number(qty)<1||Number(qty)>50||!/^\d+$/.test(f(fd,'version_'+id)))return fail('Use whole item quantities of 1–50.');const menuId=f(fd,'menu_'+id)||id,variant=f(fd,'variant_'+id),variantVersion=f(fd,'variant_version_'+id);if(!validId(menuId)||variant&&(!validId(variant)||!/^\d+$/.test(variantVersion)))return fail('Review the selected item size.');items.push({menu_item_id:menuId,quantity:Number(qty),version:Number(f(fd,'version_'+id)),...(variant?{variant_id:variant,variant_version:Number(variantVersion)}:{})});}
 if(!items.length||items.length>30)return fail('Choose 1–30 different menu items.');
 const quote=inventoryMoney(f(fd,'quote'));if(!quote)return fail('Review the cart total before placing the order.');
 const{data,error}=await db.rpc('orders_create',{p_property:pid,p_request:request,p_details:{kind,reservation_id:reservation||null,table:f(fd,'table'),notes:f(fd,'notes'),priority:f(fd,'priority'),target_minutes:target,items,quote,expected_currency:f(fd,'currency')}});if(error)return fail(message(error));refresh(pid);redirect(`/p/${pid}/orders/${data}?notice=created`);
}
export async function orderOperation(_:OrderState,fd:FormData):Promise<OrderState>{
 const pid=f(fd,'pid'),id=f(fd,'id'),request=f(fd,'request'),op=f(fd,'operation'),version=Number(f(fd,'version')),fields=snapshot(fd),fail=(error:string)=>({error,fields});
 if(!validId(pid)||!validId(id)||!validId(request)||!Number.isInteger(version)||version<1||!['status','triage','comment','payment','refund'].includes(op))return fail('Reload this order.');
 const details:Record<string,string>={};
 if(op==='status'){details.status=f(fd,'status');if(!['preparing','ready','serving','serving','served','cancelled'].includes(details.status))return fail('Choose a valid kitchen status.');if(details.status==='cancelled'){details.reason=f(fd,'reason');if(details.reason.length<3||details.reason.length>500)return fail('Enter a cancellation reason of 3–500 characters.');}}
 if(op==='triage'){details.priority=f(fd,'priority');details.deadline=f(fd,'deadline');details.target_minutes=f(fd,'target_minutes');if(!['normal','high','urgent'].includes(details.priority)||!['keep','set','clear'].includes(details.deadline)||details.deadline==='set'&&(!/^\d{1,4}$/.test(details.target_minutes)||Number(details.target_minutes)<1||Number(details.target_minutes)>1440))return fail('Choose a priority and valid response target.');}
 if(op==='comment'){details.body=f(fd,'body');if(!details.body||details.body.length>2000)return fail('Write a comment of 1–2000 characters.');}
 if(op==='payment'){details.method=f(fd,'method');details.reference=f(fd,'reference');details.expected_total=f(fd,'expected_total');if(!paymentMethods.includes(details.method as typeof paymentMethods[number])||details.reference.length>120||!parseAmount(details.expected_total))return fail('Choose a payment method and valid order total.');if(f(fd,'confirm')!=='yes')return fail('Confirm that this payment was received.');}
 if(op==='refund'){details.payment_id=f(fd,'payment_id');details.expected_refundable=f(fd,'expected_refundable');details.amount=f(fd,'amount');details.reason=f(fd,'reason');if(!validId(details.payment_id)||!parseAmount(details.amount)||!parseAmount(details.expected_refundable)||details.reason.length<3||details.reason.length>500)return fail('Choose the payment, a positive refund amount, and a reason of 3–500 characters.');if(f(fd,'confirm')!=='yes')return fail('Confirm that this refund should be recorded.');}
 const db=await createClient(),{error}=await db.rpc('order_action',{p_property:pid,p_id:id,p_version:version,p_request:request,p_action:op,p_details:details});if(error)return fail(message(error));refresh(pid);redirect(`/p/${pid}/orders/${id}?notice=${op}`);
}
export async function saveOrderMenu(_:OrderState,fd:FormData):Promise<OrderState>{
 const pid=f(fd,'pid'),id=f(fd,'id'),request=f(fd,'request'),version=Number(f(fd,'version')),fields=snapshot(fd);fields.active=f(fd,'active')==='yes'?'true':'false';const fail=(error:string)=>({error,fields});
 if(!validId(pid)||!validId(request)||id&&(!validId(id)||!Number.isInteger(version)||version<1))return fail('Reload this menu form.');
 const diet=f(fd,'dietary_type'),scope=f(fd,'service_scope'),mode=f(fd,'pricing_mode'),image=f(fd,'image_id');
 if(!Object.hasOwn(foodTypes,diet)||!Object.hasOwn(foodServices,scope)||!['single','sizes'].includes(mode)||image&&!validId(image))return fail('Choose the food type, service destination, pricing and food photo.');
 let sizes:ReturnType<typeof foodSizePayload>=[];try{if(mode==='sizes')sizes=foodSizePayload(f(fd,'variants'));}catch(e){return fail(e instanceof Error?e.message:'Check the size prices.');}
 const price=inventoryMoney(mode==='sizes'?sizes.reduce((a,b)=>Number(a.price)<=Number(b.price)?a:b).price:f(fd,'price')),tax=inventoryMoney(f(fd,'tax'));
 if(!price||!tax||Number(tax)>100||f(fd,'name').length<2||f(fd,'name').length>120||f(fd,'category').length<2||f(fd,'category').length>80||f(fd,'description').length>800||f(fd,'dietary_notes').length>200)return fail('Check the name, category, prices, tax (0–100%), description and dietary notes.');
 const prep=f(fd,'prep_minutes');if(prep&&(!/^\d{1,3}$/.test(prep)||Number(prep)<1||Number(prep)>240))return fail('Use a preparation target of 1–240 whole minutes, or leave it blank.');
 const db=await createClient(),{data,error}=await db.rpc('order_menu_save',{p_property:pid,p_request:request,p_id:id||null,p_version:id?version:null,p_details:{name:f(fd,'name'),category:f(fd,'category'),description:f(fd,'description'),dietary_notes:f(fd,'dietary_notes'),price,tax,prep_minutes:prep,active:fields.active==='true',dietary_type:diet,service_scope:scope,pricing_mode:mode,image_id:image||null,variants:mode==='sizes'?sizes:[]}});
 if(error)return fail(message(error));refresh(pid);redirect(`/p/${pid}/orders/menu?notice=saved`);
}
export async function menuLifecycle(_:OrderState,fd:FormData):Promise<OrderState>{
 const pid=f(fd,'pid'),id=f(fd,'id'),request=f(fd,'request'),version=Number(f(fd,'version')),op=f(fd,'operation');
 if(!validId(pid)||!validId(id)||!validId(request)||!Number.isInteger(version)||!['delete','restore'].includes(op)||f(fd,'confirm')!=='yes')return{error:'Confirm this menu action before continuing.'};
 const db=await createClient(),{error}=await db.rpc('order_menu_lifecycle',{p_property:pid,p_id:id,p_version:version,p_request:request,p_action:op});
 if(error)return{error:message(error)};refresh(pid);redirect(`/p/${pid}/orders/menu?state=${op==='delete'?'active':'inactive'}&notice=${op==='delete'?'deleted':'restored'}`);
}

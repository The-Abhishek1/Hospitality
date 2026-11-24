'use server';
import {createClient} from '@/lib/supabase/server';
import {revalidatePath} from 'next/cache';
import {validId} from '@/lib/reservations';
type State={error?:string;success?:string};
export async function paymentAction(_:State,fd:FormData):Promise<State>{
 const pid=String(fd.get('pid')??''),rid=String(fd.get('reservation')??''),intent=String(fd.get('intent')??''),id=String(fd.get('id')??'');
 if(!validId(pid)||!validId(id))return{error:'Refresh the payment form.'};const db=await createClient();let result;
 if(intent==='request'&&validId(rid))result=await db.rpc('request_online_payment',{p_property:pid,p_reservation:rid,p_request:id,p_send:fd.get('send')==='on'});
 else if(intent==='cancel')result=await db.rpc('cancel_online_payment',{p_property:pid,p_request:id});
 else if(intent==='reconcile')result=await db.rpc('reconcile_online_payment',{p_property:pid,p_request:id});
 else if(['enable','pause','disconnect'].includes(intent))result=await db.rpc('payment_connection_action',{p_property:pid,p_connection:id,p_version:Number(fd.get('version')),p_action:intent});
 else return{error:'Choose a valid payment action.'};
 if(result.error)return{error:['22023','42501','40001'].includes(result.error.code)?result.error.message:'Could not update this payment. Refresh and reconcile before trying again.'};
 revalidatePath(`/p/${pid}/billing`,'layout');revalidatePath(`/p/${pid}/reservations`,'layout');revalidatePath('/dashboard');
 return{success:intent==='request'?'Payment link requested. Its status updates automatically.':intent==='cancel'?'Cancellation requested. Wait for provider confirmation before taking another payment.':intent==='reconcile'?'Payment check requested.':'Payment connection updated.'};
}

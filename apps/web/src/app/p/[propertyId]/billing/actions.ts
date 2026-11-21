"use server";
import {redirect} from 'next/navigation';
import {revalidatePath} from 'next/cache';
import {createClient} from '@/lib/supabase/server';
import {validId,validDay} from '@/lib/reservations';
import {parseAmount,paymentMethods,type AuditSummary} from '@/lib/billing';
export type BillingState={error?:string;success?:string;summary?:AuditSummary;request?:string;fields?:Record<string,string>};
const field=(fd:FormData,key:string)=>String(fd.get(key)??'').trim();
const friendly=(e:{code?:string;message:string})=>e.code==='42501'?'Your role does not allow this billing action.':e.code==='40001'?'The folio balance changed. Refresh and review the latest activity before recording another transaction.':e.code==='23505'?'This transaction reference is already recorded. Check payment history before trying again.':['22023','P0002'].includes(e.code??'')?e.message:'Couldn’t save this transaction. Refresh and check the ledger before trying again.';
export async function billingOperation(_:BillingState,fd:FormData):Promise<BillingState>{
 const pid=field(fd,'pid'),reservation=field(fd,'reservation'),request=field(fd,'request'),operation=field(fd,'operation');
 const fields=Object.fromEntries(['amount','method','reference','description','reason','payment_id','operation'].map(k=>[k,field(fd,k).slice(0,500)]));
 const fail=(error:string)=>({error,fields});
 if(!validId(pid)||!validId(reservation)||!validId(request))return fail('Reload this folio and try again.');
 if(!['payment','charge','credit','refund','post_rooms','invoice'].includes(operation))return fail('Choose a valid billing action.');
 if(field(fd,'confirm')!=='yes')return fail('Confirm the transaction details before saving.');
 const details:Record<string,string|boolean>={expected_balance:field(fd,'balance')};
 if(['payment','charge','credit','refund'].includes(operation)){
  const amount=parseAmount(field(fd,'amount'));if(!amount)return fail('Enter a positive amount with at most two decimal places.');details.amount=amount;
 }
 if(operation==='payment'){
  const method=field(fd,'method');if(!paymentMethods.includes(method as typeof paymentMethods[number]))return fail('Choose a payment method.');
  if(['card','upi','bank_transfer'].includes(method)&&field(fd,'reference').length<3)return fail('Enter the transaction or receipt reference for this payment.');
  if(field(fd,'reference').length>200)return fail('Keep the reference under 200 characters.');
  details.method=method;details.reference=field(fd,'reference');details.allow_credit=field(fd,'allow_credit')==='yes';
 }
 if(['charge','credit'].includes(operation)){const description=field(fd,'description');if(description.length<3||description.length>300)return fail('Enter a description (3–300 characters).');details.description=description;}
 if(operation==='refund'){const payment=field(fd,'payment_id'),reason=field(fd,'reason');if(!validId(payment))return fail('Select the payment to refund.');if(reason.length<3||reason.length>500)return fail('Enter a refund reason (3–500 characters).');details.payment_id=payment;details.reason=reason;}
 const db=await createClient();const {data,error}=await db.rpc('billing_action',{p_property:pid,p_reservation:reservation,p_request:request,p_action:operation,p_details:details});
 if(error)return fail(friendly(error));
 revalidatePath('/dashboard');revalidatePath(`/p/${pid}/billing`,'layout');revalidatePath(`/p/${pid}/reservations`,'layout');
 if(operation==='invoice')redirect(`/p/${pid}/billing/invoices/${data.id}`);
 redirect(`/p/${pid}/billing/${reservation}?notice=${operation}`);
}
export async function auditOperation(_:BillingState,fd:FormData):Promise<BillingState>{
 const pid=field(fd,'pid'),request=field(fd,'request'),day=field(fd,'day');
 if(!validId(pid)||!validId(request)||!validDay(day))return{error:'Choose a valid hotel and business date.'};
 if(field(fd,'confirm')!=='yes')return{error:'Confirm that room charges will be posted through the selected date.'};
 const db=await createClient();const {data,error}=await db.rpc('billing_run_audit',{p_property:pid,p_date:day,p_request:request});
 if(error)return{error:friendly(error)};revalidatePath('/dashboard');revalidatePath(`/p/${pid}/billing`,'layout');return{success:'Night audit completed.',summary:data as AuditSummary,request,fields:{day}};
}

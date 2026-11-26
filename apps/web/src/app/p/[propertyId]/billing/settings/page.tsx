import Link from 'next/link';import {createClient} from '@/lib/supabase/server';import {PaymentConnection} from '@/components/payments/connection';import type {PaymentWorkspace} from '@/lib/online-payments';
import '@/components/billing/billing.css';import '@/components/payments/payments.css';
export const metadata={title:'Online payment settings · Hospitality'};
export default async function Payments({params}:{params:Promise<{propertyId:string}>}){
 const{propertyId:pid}=await params,db=await createClient(),{data,error}=await db.rpc('payment_workspace',{p_property:pid});
 if(error||!data)return <section><h1>Online payments</h1><p>Billing access is required for this hotel.</p></section>;
 const configured=/^[a-f0-9]{64}$/i.test(process.env.PAYMENTS_ENCRYPTION_KEY||process.env.WHATSAPP_ENCRYPTION_KEY||'');
 return <div className="billing-workspace"><header className="pay-page-heading"><Link href={`/p/${pid}/billing`}>← Billing</Link><h1>Online payments</h1><p>Connect this hotel’s own Razorpay account for booking deposits and checkout payments.</p></header><PaymentConnection key={`${data.connection?.id??'new'}-${data.connection?.version??0}`} pid={pid} data={data as PaymentWorkspace} origin={(process.env.APP_URL||'http://localhost:3000').replace(/\/$/,'')} configured={configured}/></div>;
}

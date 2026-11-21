import {NextResponse,type NextRequest} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {validId} from '@/lib/reservations';
import {csvText,csvMoney,type LedgerEntry} from '@/lib/billing';
export async function GET(_request:NextRequest,{params}:{params:Promise<{propertyId:string;reservationId:string}>}){
 const {propertyId:pid,reservationId:id}=await params;if(!validId(pid)||!validId(id))return NextResponse.json({error:'Folio not found.'},{status:404});
 const db=await createClient();const {data,error}=await db.rpc('billing_export',{p_property:pid,p_reservation:id});
 if(error)return NextResponse.json({error:error.code==='42501'?'Billing access required.':error.code==='54000'?error.message:'Could not export this folio.'},{status:error.code==='42501'?403:400});
 const lines=[['Recorded at','Type','Description','Change','Running balance','Currency','Method','Reference','Staff'].map(csvText).join(',')];
 for(const e of data.entries as LedgerEntry[])lines.push([csvText(e.created_at),csvText(e.kind),csvText(e.description),csvMoney(e.amount),csvMoney(e.running_balance),csvText(data.currency),csvText(e.method),csvText(e.reference),csvText(e.actor_name)].join(','));
 return new Response('\uFEFF'+lines.join('\r\n'),{headers:{'Content-Type':'text/csv; charset=utf-8','Content-Disposition':`attachment; filename="folio-${id}.csv"`,'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'}});
}

import Link from 'next/link';
import {createClient} from '@/lib/supabase/server';
import {PermissionForm} from '@/components/campaigns/controls';
import '@/components/service-desk/service-desk.css';
import '../campaigns.css';
export default async function PermissionPage({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{guest?:string}>}){
 const{propertyId:pid}=await params,guest=(await searchParams).guest,db=await createClient();
 const{data:access,error}=await db.rpc('campaign_audience',{p_property:pid,p_filters:{status:'all',q:''},p_page:1});
 if(error||!access||!guest)return <p>Hotel campaign management access is required.</p>;
 const{data:stay}=await db.from('reservations').select('guest:guests(id,full_name,phone)').eq('property_id',pid).eq('guest_id',guest).limit(1).maybeSingle();
 const g=Array.isArray(stay?.guest)?stay.guest[0]:stay?.guest;
 if(!g)return <p>Guest not found in this hotel.</p>;
 return <div className="service-workspace"><Link href={`/p/${pid}/campaigns`}>← Campaigns</Link><section className="campaign-panel"><h2>Marketing permission</h2><p>{g.full_name} · {g.phone||'No phone recorded'}</p><p>Record the guest’s actual permission and its source. This applies to this hotel and phone number only.</p><PermissionForm pid={pid} guest={g.id}/></section></div>;
}

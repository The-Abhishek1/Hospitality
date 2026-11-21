import Link from 'next/link';
import {randomUUID} from 'node:crypto';
import {createClient} from '@/lib/supabase/server';
import {defaultCampaignFilters,type CampaignAudience,campaignPage,campaignTime} from '@/lib/campaigns';
import {CampaignComposer} from '@/components/campaigns/composer';
import '@/components/service-desk/service-desk.css';
import './campaigns.css';
export const metadata={title:'WhatsApp campaigns · Hospitality'};
export default async function Campaigns({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{page?:string}>}){
 const{propertyId:pid}=await params,page=campaignPage((await searchParams).page),db=await createClient();
 const[{data:audience,error},{data:templates},{data:campaigns,count},{data:property}]=await Promise.all([
 db.rpc('campaign_audience',{p_property:pid,p_filters:defaultCampaignFilters,p_page:1}),
 db.from('message_templates').select('id,name,language,body').eq('property_id',pid).eq('status','approved').eq('category','marketing').eq('campaign_supported',true),
 db.from('whatsapp_campaigns').select('id,name,status,scheduled_at,created_at',{count:'exact'}).eq('property_id',pid).order('created_at',{ascending:false}).order('id').range((page-1)*20,page*20-1),
 db.from('properties').select('timezone').eq('id',pid).single()]);
 if(error)return <p role="alert">Campaign management could not be loaded. Hotel administrator access and the campaign database update are required.</p>;
 return <div className="service-workspace"><div className="sr-toolbar"><div><span className="sr-eyebrow">Guest relationships</span><h2>WhatsApp campaigns</h2><p>Reach past guests with offers and updates, now or on a schedule.</p></div><Link className="dash-button dash-secondary" href={`/p/${pid}/guest-messaging`}>Guest messaging studio →</Link></div>
 <section className="campaign-panel"><h2>Your campaigns</h2><div className="sr-table-scroll"><table className="sr-table"><thead><tr><th>Campaign</th><th>Status</th><th>Scheduled · {property?.timezone}</th><th>Review</th></tr></thead><tbody>{campaigns?.map(c=><tr key={c.id}><td>{c.name}</td><td>{c.status==='completed'?'Dispatch finished':c.status}</td><td>{c.scheduled_at?campaignTime(c.scheduled_at,property?.timezone||'Asia/Kolkata'):'Not scheduled'}</td><td><Link href={`/p/${pid}/campaigns/${c.id}`}>Open campaign →</Link></td></tr>)}</tbody></table></div>{!campaigns?.length&&<p>No campaigns yet. Build your first audience below.</p>}<div className="sr-pagination"><span>{count??0} campaigns · Page {page}</span><div>{page>1&&<Link href={`?page=${page-1}`}>← Previous</Link>}{page*20<(count??0)&&<Link href={`?page=${page+1}`}>Next →</Link>}</div></div></section>
 <CampaignComposer pid={pid} request={randomUUID()} initial={audience as CampaignAudience} templates={(templates??[]).filter(t=>!t.body.includes('{{'))}/>
 </div>;
}

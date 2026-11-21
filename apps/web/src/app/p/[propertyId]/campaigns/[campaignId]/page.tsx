import Link from 'next/link';
import {randomUUID}from 'node:crypto';
import {createClient} from '@/lib/supabase/server';
import {campaignPage,campaignTime} from '@/lib/campaigns';
import {CampaignControls,CampaignDraftEditor} from '@/components/campaigns/controls';
import '@/components/service-desk/service-desk.css';
import '../campaigns.css';
export const metadata={title:'Review campaign · Hospitality'};
export default async function CampaignDetail({params,searchParams}:{params:Promise<{propertyId:string;campaignId:string}>;searchParams:Promise<{page?:string}>}){
 const{propertyId:pid,campaignId:id}=await params,page=campaignPage((await searchParams).page),db=await createClient(),{data,error}=await db.rpc('whatsapp_campaign_report',{p_property:pid,p_campaign:id,p_page:page});
 if(error)return <p role="alert">This campaign is unavailable or you do not have campaign management access.</p>;
 const c=data.campaign,a=data.audience,zone=c.schedule_timezone||data.timezone;
 const templates=c.status==='draft'?(await db.from('message_templates').select('id,name,language,body').eq('property_id',pid).eq('status','approved').eq('category','marketing').eq('campaign_supported',true)).data??[]:[];
 return <div className="service-workspace"><Link href={`/p/${pid}/campaigns`}>← Campaigns</Link><section className="campaign-panel"><span className="sr-eyebrow">{c.status==='completed'?'Dispatch finished':c.status}</span><h2>{c.name}</h2><p>{c.scheduled_at?`Scheduled ${campaignTime(c.scheduled_at,zone)} · ${zone}`:'Draft · review your message and audience before scheduling.'}</p>
 {c.last_error&&<p role="alert">{c.last_error}</p>}<div className="campaign-message-preview"><small>Exact campaign message</small><p>{c.body}</p></div>
 <p className="campaign-note">{c.status==='draft'?'The audience below is a live preview. Scheduling freezes eligible recipients; permission is rechecked before delivery.':'Recipients were frozen at scheduling. New matching guests are not silently added.'}</p>
 <div className="campaign-stats"><div><strong>{a.total}</strong><span>{c.status==='draft'?'matched contacts':'scheduled recipients'}</span></div>{c.status==='draft'?<><div><strong>{a.eligible}</strong><span>eligible</span></div><div><strong>{a.total-a.eligible}</strong><span>excluded</span></div></>:Object.entries(a.counts??{}).map(([status,n])=><div key={status}><strong>{String(n)}</strong><span>{status}</span></div>)}</div>
 <div className="sr-table-scroll"><table className="sr-table"><thead><tr><th>Guest</th><th>Phone</th><th>{c.status==='draft'?'Eligibility':'Delivery status'}</th></tr></thead><tbody>{a.rows.map((r:any)=><tr key={r.id||r.guest_id}><td>{r.guest_name}</td><td>{r.phone?'+'+r.phone:'Invalid phone'}</td><td>{c.status==='draft'?r.exclusion||'Eligible':r.state}{r.reason&&<small>{r.reason}</small>}</td></tr>)}</tbody></table></div>
 <div className="sr-pagination"><span>Page {page} · 30 contacts per page</span><div>{page>1&&<Link href={`?page=${page-1}`}>← Previous</Link>}{page*30<a.total&&<Link href={`?page=${page+1}`}>Next →</Link>}</div></div>
 {c.status==='draft'&&<CampaignDraftEditor key={`edit-${c.version}`} pid={pid} id={id} version={c.version} request={randomUUID()} body={c.body} template={c.template_id} templates={templates.filter(t=>!t.body.includes('{{'))}/>}
 <CampaignControls key={c.version} pid={pid} id={id} version={c.version} status={c.status} timezone={zone} eligible={a.eligible??0}/>
 <p className="campaign-note">“Sent” means accepted by WhatsApp; delivered and read are separate provider receipts. “Dispatch finished” can include failures and skipped contacts.</p>
 </section></div>;
}

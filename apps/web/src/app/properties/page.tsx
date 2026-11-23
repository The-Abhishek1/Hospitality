import Link from 'next/link';
import { redirect } from 'next/navigation';
import { randomUUID } from 'node:crypto';
import { createClient } from '@/lib/supabase/server';
import { WorkspaceFrame } from '@/components/workspace/frame';
import { PropertyForm } from '@/components/properties/property-form';
import '@/components/workspace/workspace.css';
export const metadata={title:'Manage properties · Hospitality'};
export default async function PropertiesPage({searchParams}:{searchParams:Promise<{tenant?:string;property?:string;view?:string;notice?:string}>}){
 const params=await searchParams,db=await createClient();
 const {data:{user}}=await db.auth.getUser();if(!user)redirect('/login');
 const [tr,pr,mr]=await Promise.all([
  db.from('tenants').select('id,name').order('name'),
  db.from('properties').select('id,tenant_id,name,property_type,timezone,currency,city,country_code,archived_at').order('name'),
  db.from('tenant_memberships').select('tenant_id,role').eq('user_id',user.id),
 ]);
 if(tr.error||pr.error||mr.error)throw new Error('Could not load your properties. Please refresh.');
 const tenants=tr.data??[],properties=pr.data??[],memberships=mr.data??[];
 if(!tenants.length)redirect('/onboarding');
 const tenant=tenants.find(t=>t.id===params.tenant)??tenants[0];
 const canManage=memberships.some(m=>m.tenant_id===tenant.id&&['owner','admin'].includes(m.role));
 const active=properties.filter(p=>!p.archived_at),archivedView=params.view==='archived';
 const tenantProperties=properties.filter(p=>p.tenant_id===tenant.id),list=tenantProperties.filter(p=>Boolean(p.archived_at)===archivedView);
 const property=list.find(p=>p.id===params.property)??list[0];
 const {data:permissions}=property?await db.rpc('workspace_permissions',{p_property:property.id}):{data:{}};
 const name=typeof user.user_metadata?.full_name==='string'?user.user_metadata.full_name.split(' ')[0]:'Team member';
 const content=<div className="space-y-8">{params.notice&&<p role="status" className="property-help">{params.notice==='archived'?'Hotel archived. Other hotels remain active.':'Hotel reopened. Review integrations and guest links before resuming operations.'}</p>}
  <section><div className="property-section-heading"><div><h2>{archivedView?'Archived properties':'Your properties'}</h2><p className="property-help">One business account. Separate operations for every hotel.</p></div>{canManage&&<a href="#add-property" className="dash-button">＋ Add property</a>}</div>
   <nav className="property-status-tabs" aria-label="Property status"><Link aria-current={!archivedView?'page':undefined} href={`/properties?tenant=${tenant.id}`}>Active ({tenantProperties.filter(p=>!p.archived_at).length})</Link>{canManage&&<Link aria-current={archivedView?'page':undefined} href={`/properties?tenant=${tenant.id}&view=archived`}>Archived ({tenantProperties.filter(p=>p.archived_at).length})</Link>}</nav><form method="get" className="property-business-filter"><input type="hidden" name="view" value={archivedView?'archived':'active'}/><label htmlFor="business">Business</label><select id="business" name="tenant" defaultValue={tenant.id}>{tenants.map(t=><option key={t.id} value={t.id}>{t.name}</option>)}</select><button type="submit" className="dash-button dash-secondary">View business</button></form>
   <div className="property-cards">{list.map(p=><article key={p.id} className="property-card"><div className="property-card-top"><span className="property-type">{p.archived_at?'Archived':p.property_type}</span>{p.id===property?.id&&<span className="dash-badge green">Selected</span>}</div><h3>{p.name}</h3><p>{[p.city,p.country_code].filter(Boolean).join(', ')}</p><dl><div><dt>Timezone</dt><dd>{p.timezone}</dd></div><div><dt>Currency</dt><dd>{p.currency}</dd></div></dl><div className="property-card-actions"><Link className="dash-button" href={p.archived_at?`/p/${p.id}/reservations`:`/dashboard?property=${p.id}`}>{p.archived_at?'View booking history':'Open hotel ↗'}</Link>{canManage&&<>{!p.archived_at&&<Link href={`/p/${p.id}/settings`}>Configure →</Link>}<Link href={`/properties/${p.id}/lifecycle`}>{p.archived_at?'Review & reopen →':'Close & archive →'}</Link></>}</div></article>)}</div>
   {!list.length&&<p className="dash-empty">{archivedView?'No archived properties in this business.':'No active properties in this business. Add a hotel below or reopen an archived property.'}</p>}
  </section>
  {canManage?<section id="add-property"><h2>Add a property to {tenant.name}</h2><p className="property-help">Your existing login manages this hotel too. Staff are assigned separately through Team & access.</p><PropertyForm key={tenant.id} tenant={tenant.id} request={randomUUID()} property={{name:'',property_type:'hotel',timezone:'Asia/Kolkata',currency:'INR',address:'',city:'',country_code:'IN',contact_email:'',contact_phone:''}} timezones={Intl.supportedValuesOf('timeZone')} currencies={Intl.supportedValuesOf('currency')}/></section>:<section><h2>Need another property?</h2><p>Ask your business owner or administrator to add it and assign your access.</p></section>}
 </div>;
 return property?<WorkspaceFrame properties={active} property={property} name={name} tenantName={tenant.name} permissions={permissions??{}} teamAccess={canManage}>{content}</WorkspaceFrame>:<main className="dash-fallback property-empty-workspace"><Link href="/dashboard" className="dash-wordmark">h· hospitality</Link><h1>Manage properties</h1><div className="workspace-feature-body">{content}</div></main>;
}

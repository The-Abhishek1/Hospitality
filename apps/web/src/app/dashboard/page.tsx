import Link from 'next/link';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { RefreshDashboard } from '@/components/dashboard/controls';
import { TodayStays, type Stay } from '@/components/dashboard/stays';
import { signOut } from './actions';
import { WorkspaceFrame } from '@/components/workspace/frame';
import '@/components/workspace/workspace.css';
import './overview.css';
export const metadata = { title: 'Hotel overview · Hospitality' };
type Snapshot = {
  day: string; updated_at: string; units: number;
  permissions: Record<string, boolean>;
  rooms: { clean: number; dirty: number; in_progress: number };
  forecast: { day: string; booked: number; blocked: number }[];
  tasks: { open: number; overdue: number };
  task_list: { id: string; title: string; kind: string; priority: string; due_at: string | null; status: string }[];
  arrivals?: number; arrivals_pending?: number; departures?: number; departures_pending?: number;
  in_house?: number; late_arrivals?: number; stays?: Stay[]; collections?: number; refunds_today?: number;
  outstanding?: number; conversations?: number; channel_failures?: number;
};
export default async function Dashboard({ searchParams }: { searchParams: Promise<{ property?: string; error?: string; workspace?: string }> }) {
  const params = await searchParams, db = await createClient();
  const { data: { user } } = await db.auth.getUser();
  if (!user) redirect('/login');
  const {data:platformAdmin}=await db.from('platform_admins').select('user_id').eq('user_id',user.id).maybeSingle();
  if(platformAdmin&&params.workspace!=='hotel'&&!params.property)redirect('/admin');
  const { error: inviteError } = await db.rpc('accept_staff_invitations');
  const [tenantResult,propertyResult,membershipResult] = await Promise.all([
    db.from('tenants').select('id,name,status'),
    db.from('properties').select('id,tenant_id,name,property_type,timezone,currency,archived_at').order('name'),
    db.from('tenant_memberships').select('tenant_id,role').eq('user_id',user.id),
  ]);
  if(params.property&&propertyResult.data?.some(p=>p.id===params.property&&p.archived_at))redirect(`/properties/${params.property}/lifecycle`);
  const properties = (propertyResult.data ?? []).filter(p=>!p.archived_at), tenants = tenantResult.data ?? [];
  if (!tenantResult.error && !propertyResult.error && !tenants.length) redirect('/onboarding');
  if (tenantResult.error || propertyResult.error) return <main className="dash-fallback"><h1>We couldn’t load your workspace</h1><p>Please try again in a moment.</p><RefreshDashboard /></main>;
  if(!properties.length&&tenants.some(t=>t.status!=='active'))return <main className="dash-fallback"><span className="dash-wordmark">h· hospitality</span><h1>Your business account is unavailable.</h1><p>Hotel access is paused for {tenants.filter(t=>t.status!=='active').map(t=>t.name).join(', ')}. Contact platform support to review the account status.</p>{platformAdmin&&<Link href="/admin">Open platform console →</Link>}<form action={signOut}><button className="dash-button">Sign out</button></form></main>;
  if (!properties.length) return <main className="dash-fallback"><span className="dash-wordmark">h· hospitality</span><h1>Your workspace is almost ready.</h1><p>No active hotels are available to your account. Open Manage properties to add a hotel or reopen an archived one, or ask your administrator to assign access.</p><Link className="dash-button" href="/properties">Manage / add properties →</Link>{tenants.map(t => <Link key={t.id} href={`/t/${t.id}/team`}>View {t.name} team →</Link>)}<form action={signOut}><button className="dash-button">Sign out</button></form></main>;
  const property = properties.find(p => p.id===params.property) ?? properties[0];
  const tenant = tenants.find(t => t.id===property.tenant_id);
  const [{data,error},{data:workspacePermissions}]=await Promise.all([db.rpc('dashboard_snapshot',{p_property:property.id}),db.rpc('workspace_permissions',{p_property:property.id})]);
  const s = data as Snapshot | null;
  if (error || !s) return <main className="dash-fallback"><h1>Your overview is temporarily unavailable</h1><p>We couldn’t load hotel insights. Refresh to try again, or open your hotel directly.</p><RefreshDashboard /><Link href={`/p/${property.id}/reservations`}>Open hotel →</Link></main>;
  const p={...s.permissions,...workspacePermissions}, base=`/p/${property.id}`;
  const name = typeof user.user_metadata?.full_name==='string' ? user.user_metadata.full_name.split(' ')[0] : 'there';
  const date = new Intl.DateTimeFormat('en', {weekday:'long',day:'numeric',month:'long',year:'numeric',timeZone:'UTC'}).format(new Date(`${s.day}T12:00:00Z`));
  const money = (amount: number | undefined) => amount===undefined ? '—' : new Intl.NumberFormat('en-IN',{style:'currency',currency:property.currency,maximumFractionDigits:0}).format(Number(amount));
  const today=s.forecast[0], occupied=today?.booked ?? 0, blocked=today?.blocked ?? 0;
  const occupancy=s.units ? Math.round(occupied/s.units*100) : 0;
  const available=Math.max(0,s.units-occupied-blocked);
  const alerts = [
    ...(s.departures_pending ? [{title:`${s.departures_pending} departure${s.departures_pending===1?'':'s'} to complete`,text:'Review folios before checking guests out.',href:p.finance ? `${base}/billing` : `${base}/reservations`}] : []),
    ...(s.late_arrivals ? [{title:`${s.late_arrivals} past-due arrival${s.late_arrivals===1?'':'s'}`,text:'Confirm arrival plans or review no-shows.',href:`${base}/reservations`}] : []),
    ...(p.tasks && s.tasks.overdue ? [{title:`${s.tasks.overdue} overdue task${s.tasks.overdue===1?'':'s'}`,text:'Review the tasks visible to your role.',href:`${base}/tasks?view=overdue`}] : []),
    ...(s.channel_failures ? [{title:`${s.channel_failures} channel issue${s.channel_failures===1?'':'s'}`,text:'Review failed imports and availability syncs.',href:`${base}/channels`}] : []),
  ];
  const membership=membershipResult.data?.find(m=>m.tenant_id===property.tenant_id);
  return <WorkspaceFrame platformAccess={!!platformAdmin} properties={properties} property={property} name={name} tenantName={tenant?.name ?? ''} permissions={p} teamAccess={membership?.role==='owner'||membership?.role==='admin'} inboxCount={s.conversations}>
      <div className="overview-page">
        {(params.error || inviteError) && <div className="dash-warning" role="alert">{params.error || 'We couldn’t check pending invitations. Refresh to try again.'}</div>}
        <header className="overview-heading">
          <div><h1>Overview</h1><p>{date}</p></div>
          <div className="overview-actions"><RefreshDashboard />{p.book && <Link className="dash-button" href={`${base}/reservations/new`}>＋ New reservation</Link>}</div>
        </header>
        <p className="overview-updated">Updated {new Intl.DateTimeFormat('en',{hour:'numeric',minute:'2-digit',timeZone:property.timezone}).format(new Date(s.updated_at))} · {property.timezone}</p>
        <section className="overview-metrics" aria-label="Today’s numbers">
          <Metric label="Occupancy tonight" value={`${occupancy}%`} detail={`${occupied} of ${s.units} units booked`} href={p.reservations ? `${base}/reservations?mode=calendar` : undefined} />
          <Metric label="Arrivals today" value={s.arrivals} detail={p.reservations ? `${s.arrivals_pending ?? 0} to check in` : 'Reservation access required'} href={p.reservations ? `${base}/reservations?view=arrivals` : undefined} />
          <Metric label="Departures today" value={s.departures} detail={p.reservations ? `${s.departures_pending ?? 0} to check out` : 'Reservation access required'} href={p.reservations ? `${base}/reservations?view=departures` : undefined} />
          <Metric label="Collected today" value={p.finance ? money(s.collections) : '—'} detail={p.finance ? `Gross receipts · ${money(s.refunds_today)} refunded` : 'Finance access required'} href={p.finance ? `${base}/billing` : undefined} />
        </section>
        {alerts.length > 0 && <section className="overview-attention" aria-labelledby="overview-attention-title"><h2 id="overview-attention-title">Needs attention</h2><ul>{alerts.map(a=><li key={a.title}><Link href={a.href}><span><strong>{a.title}</strong><span>{a.text}</span></span><span aria-hidden="true">→</span></Link></li>)}</ul></section>}
        <div className="overview-main">
          <TodayStays stays={s.stays ?? []} day={s.day} property={property.id} canRead={p.reservations} totals={{arrivals:s.arrivals ?? 0,departures:s.departures ?? 0,inhouse:s.in_house ?? 0}} />
          <div className="overview-operations">
            <section className="overview-card"><div className="overview-card-heading"><h2>Housekeeping</h2>{p.tasks && <Link href={`${base}/tasks?mode=rooms`}>Manage rooms →</Link>}</div>
              <dl className="overview-room-counts"><div><dt>Clean</dt><dd>{s.rooms.clean}</dd></div><div><dt>Cleaning</dt><dd>{s.rooms.in_progress}</dd></div><div><dt>Needs cleaning</dt><dd>{s.rooms.dirty}</dd></div></dl>
              <p className="overview-note">{available} units unheld tonight{blocked > 0 ? ` · ${blocked} blocked` : ''}. Cleanliness is separate from availability.</p>
            </section>
            {p.tasks && <section className="overview-card"><div className="overview-card-heading"><h2>Tasks <span className="overview-count">{s.tasks.open}</span></h2><Link href={`${base}/tasks`}>View all →</Link></div>
              {s.task_list.length > 0 ? <ul className="overview-task-list">{s.task_list.map(t=><li key={t.id}><Link href={`${base}/tasks/${t.id}`}><span><strong>{t.title}</strong><small>{t.due_at ? `Due ${new Intl.DateTimeFormat('en',{month:'short',day:'numeric',hour:'numeric',minute:'2-digit',timeZone:property.timezone}).format(new Date(t.due_at))}` : 'No due date'}{t.priority==='urgent'||t.priority==='high' ? ` · ${t.priority} priority` : ''}</small></span><span aria-hidden="true">→</span></Link></li>)}</ul> : <p className="overview-note">No open tasks.</p>}
            </section>}
          </div>
        </div>
        <details className="overview-insights"><summary>More insights <span>7-day occupancy{p.finance ? ' & open balances' : ''}</span></summary>
          <div className="overview-insights-content">
            <section className="overview-card overview-forecast"><div className="overview-card-heading"><h2>Next 7 days</h2><span className="dash-chart-key"><i /> Booked <i className="blocked" /> Blocked</span></div><div className="dash-forecast">{s.forecast.map(f=>{
              const percent=s.units ? f.booked/s.units*100 : 0, blockPercent=s.units ? f.blocked/s.units*100 : 0;
              return <div key={f.day} className="dash-forecast-day"><strong>{Math.round(percent)}%</strong><div className="dash-bar-track" role="img" aria-label={`${f.day}: ${f.booked} booked, ${f.blocked} blocked, ${s.units} total`}><div className="dash-bar-fill" style={{height:`${percent}%`}} /><div className="dash-bar-blocked" style={{height:`${blockPercent}%`}} /></div><span>{new Intl.DateTimeFormat('en',{weekday:'short',timeZone:'UTC'}).format(new Date(`${f.day}T12:00:00Z`))}</span><small>{f.day.slice(8)}</small></div>;
            })}</div><p className="overview-note">Booked units ÷ active units. Blocks are shown separately.</p></section>
            {p.finance && <section className="overview-card overview-balance"><h2>Open folio balances</h2><strong>{money(s.outstanding)}</strong><p className="overview-note">Posted charges only. Unposted room nights are excluded.</p><Link href={`${base}/billing`}>Open billing →</Link></section>}
          </div>
          {p.reports && <Link className="overview-report-link" href={`${base}/reports`}>View reports & insights →</Link>}
        </details>
      </div>
  </WorkspaceFrame>;
}
function Metric({label,value,detail,href}:{label:string;value:string|number|undefined;detail:string;href?:string}) {
  const content=<><span>{label}</span><strong>{value ?? '—'}</strong><p>{detail}</p></>;
  return href ? <Link className="overview-metric" href={href}>{content}</Link> : <div className="overview-metric">{content}</div>;
}

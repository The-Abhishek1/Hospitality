import Link from 'next/link';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { RefreshDashboard } from '@/components/dashboard/controls';
import { TodayStays, type Stay } from '@/components/dashboard/stays';
import { signOut } from './actions';
import { WorkspaceFrame } from '@/components/workspace/frame';
import '@/components/workspace/workspace.css';
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
    ...(s.departures_pending ? [{title:`${s.departures_pending} departure${s.departures_pending===1?'':'s'} to complete`,text:'Review folios before checking guests out.',href:p.finance ? `${base}/billing` : `${base}/reservations`,tone:'gold'}] : []),
    ...(s.late_arrivals ? [{title:`${s.late_arrivals} past-due arrival${s.late_arrivals===1?'':'s'}`,text:'Confirm arrival plans or review no-shows.',href:`${base}/reservations`,tone:'gold'}] : []),
    ...(s.tasks.overdue ? [{title:`${s.tasks.overdue} overdue task${s.tasks.overdue===1?'':'s'}`,text:'Review the tasks visible to your role.',href:`${base}/tasks?view=overdue`,tone:'red'}] : []),
    ...(s.channel_failures ? [{title:`${s.channel_failures} channel issue${s.channel_failures===1?'':'s'}`,text:'Review failed imports and availability syncs.',href:`${base}/channels`,tone:'red'}] : []),
  ];
  const membership=membershipResult.data?.find(m=>m.tenant_id===property.tenant_id);
  return <WorkspaceFrame platformAccess={!!platformAdmin} properties={properties} property={property} name={name} tenantName={tenant?.name ?? ''} permissions={p} teamAccess={membership?.role==='owner'||membership?.role==='admin'} inboxCount={s.conversations}>
      {(params.error || inviteError) && <div className="dash-warning" role="alert">{params.error || 'We couldn’t check pending invitations. Refresh to try again.'}</div>}
      <div className="dash-page-heading"><div><span className="dash-eyebrow">YOUR DAY, AT A GLANCE</span><h1>Hello, {name}<span className="dash-greeting-dot">.</span></h1><p>Here’s what’s happening at {property.name} today.</p></div><div className="dash-heading-actions"><RefreshDashboard />{p.book && <Link className="dash-button" href={`${base}/reservations/new`}>＋ New reservation</Link>}</div></div>
      <div className="dash-date-line"><span>{date}</span><span className="dash-updated"><i /> Updated {new Intl.DateTimeFormat('en',{hour:'2-digit',minute:'2-digit',timeZone:property.timezone}).format(new Date(s.updated_at))} · refresh for latest</span></div>
      <section className="dash-metrics" aria-label="Hotel metrics">
        <Metric label="Scheduled occupancy" value={`${occupancy}%`} detail={`${occupied} of ${s.units} active units booked tonight`} icon="◔" green />
        <Metric label="Arrivals today" value={s.arrivals} detail={p.reservations ? `${s.arrivals_pending} still to check in` : 'Reservation access required'} icon="↙" />
        <Metric label="Departures today" value={s.departures} detail={p.reservations ? `${s.departures_pending} still to check out` : 'Reservation access required'} icon="↗" />
        <Metric label="Collected today" value={p.finance ? money(s.collections) : '—'} detail={p.finance ? `${money(s.refunds_today)} refunded today · gross receipts` : 'Finance access required'} icon="▧" />
      </section>
      <div className="dash-main-grid"><div className="dash-primary-column">
        <TodayStays stays={s.stays ?? []} day={s.day} property={property.id} canRead={p.reservations} />
        <section className="dash-panel"><div className="dash-panel-heading"><div><h2>The week ahead</h2><p>Scheduled bookings across your active units.</p></div><span className="dash-chart-key"><i /> Booked <i className="blocked" /> Blocked</span></div><div className="dash-forecast">{s.forecast.map(f=>{
          const percent=s.units ? f.booked/s.units*100 : 0, blockPercent=s.units ? f.blocked/s.units*100 : 0;
          return <div key={f.day} className="dash-forecast-day"><strong>{Math.round(percent)}%</strong><div className="dash-bar-track" role="img" aria-label={`${f.day}: ${f.booked} booked, ${f.blocked} blocked, ${s.units} total`}><div className="dash-bar-fill" style={{height:`${percent}%`}} /><div className="dash-bar-blocked" style={{height:`${blockPercent}%`}} /></div><span>{new Intl.DateTimeFormat('en',{weekday:'short',timeZone:'UTC'}).format(new Date(`${f.day}T12:00:00Z`))}</span><small>{f.day.slice(8)}</small></div>;
        })}</div><div className="dash-panel-footer">Occupancy = booked units ÷ active units. Blocks are shown separately.</div></section>
      </div><div className="dash-secondary-column">
        <section className="dash-panel dash-readiness"><div className="dash-panel-heading"><div><h2>Room readiness</h2><p>A little care, a better arrival.</p></div><span aria-hidden="true">✧</span></div><div className="dash-readiness-total"><strong>{s.rooms.clean}<small> / {s.units}</small></strong><span>units marked clean</span></div><div className="dash-room-meter" aria-hidden="true">{(['clean','in_progress','dirty'] as const).map(k=><span key={k} className={k} style={{width:`${s.units?s.rooms[k]/s.units*100:0}%`}} />)}</div><dl className="dash-room-list"><div><dt><i className="clean" />Clean</dt><dd>{s.rooms.clean}</dd></div><div><dt><i className="in_progress" />Being cleaned</dt><dd>{s.rooms.in_progress}</dd></div><div><dt><i className="dirty" />Needs cleaning</dt><dd>{s.rooms.dirty}</dd></div></dl><div className="dash-room-note">{available} units unheld tonight · {s.in_house ?? '—'} stays in house now. Cleanliness is separate from availability.</div>{p.tasks && <Link className="dash-inline-link" href={`${base}/tasks?mode=rooms`}>Open room readiness →</Link>}</section>
        <section className="dash-panel"><div className="dash-panel-heading"><div><h2>Needs attention</h2><p>The things worth a closer look.</p></div><span className="dash-count">{alerts.length}</span></div>{alerts.length ? <ul className="dash-alert-list">{alerts.map(a=><li key={a.title}><span className={`dash-alert-icon ${a.tone}`}>!</span><div><Link href={a.href}>{a.title} ↗</Link><p>{a.text}</p></div></li>)}</ul> : <div className="dash-all-clear"><span>✓</span><strong>Nothing flagged right now</strong><p>No alerts in the data available to your role.</p></div>}</section>
        {p.finance && <Link href={`${base}/billing`} className="dash-balance"><span>OPEN FOLIO BALANCES</span><strong>{money(s.outstanding)} <span>↗</span></strong><p>Positive balances from posted charges. Unposted room nights are excluded.</p></Link>}
      </div></div>
      <section className="dash-panel dash-team-tasks"><div className="dash-panel-heading"><div><h2>Keep the day moving</h2><p>{s.tasks.open} open tasks visible to you.</p></div>{p.tasks && <Link href={`${base}/tasks`}>View tasks ↗</Link>}</div>{s.task_list.length ? <div className="dash-task-grid">{s.task_list.map(t=><Link key={t.id} href={`${base}/tasks/${t.id}`} className="dash-task-card"><div><span className={`dash-badge ${t.priority==='urgent' || t.priority==='high' ? 'gold' : 'neutral'}`}>{t.priority}</span><span>{t.kind}</span></div><strong>{t.title}</strong><small>{t.due_at ? `Due ${new Intl.DateTimeFormat('en',{month:'short',day:'numeric',hour:'numeric',minute:'2-digit',timeZone:property.timezone}).format(new Date(t.due_at))}` : 'No deadline set'} <span>↗</span></small></Link>)}</div> : <div className="dash-empty">No open tasks available to your role.</div>}</section>
      <footer className="dash-footer"><span>Thoughtful operations. Better stays.</span><span>{property.name} · {property.currency}</span></footer>
  </WorkspaceFrame>;
}
function Metric({label,value,detail,icon,green=false}:{label:string;value:string|number|undefined;detail:string;icon:string;green?:boolean}) {
  return <div className={`dash-metric ${green?'featured':''}`}><div><span>{label}</span><i aria-hidden="true">{icon}</i></div><strong>{value ?? '—'}</strong><p>{detail}</p></div>;
}

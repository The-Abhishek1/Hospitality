
import {displayDateTime} from '@/lib/date-format';
import Link from 'next/link';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { RefreshDashboard } from '@/components/dashboard/controls';
import {TodayStayAction}from'@/components/dashboard/today-stay-action';
import{todayQueues,todayFilters,type TodaySnapshot}from'@/lib/hotel-today';
import{money,dayLabel}from'@/lib/reservations';
import { signOut } from './actions';
import { WorkspaceFrame } from '@/components/workspace/frame';
import '@/components/workspace/workspace.css';
import './overview.css';
export const metadata = { title: 'Today · Hospitality' };
export default async function Dashboard({ searchParams }: { searchParams: Promise<{ property?: string; error?: string; workspace?: string; queue?:string; page?:string }> }) {
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
  const [{data,error},{data:workspacePermissions}]=await Promise.all([db.rpc('hotel_today',{p_property:property.id,p_filters:todayFilters(params)}),db.rpc('workspace_permissions',{p_property:property.id})]);
  const s = data as TodaySnapshot | null;
  if (error || !s) return <main className="dash-fallback"><h1>Today is temporarily unavailable</h1><p>We couldn’t load today’s hotel work. Refresh to try again, or open your hotel directly.</p><RefreshDashboard /><Link href={`/p/${property.id}/reservations`}>Open hotel →</Link></main>;
  const p={...s.permissions,...workspacePermissions}, base=`/p/${property.id}`;
  const name = typeof user.user_metadata?.full_name==='string' ? user.user_metadata.full_name.split(' ')[0] : 'there';
  const date = displayDateTime(new Date(`${s.day}T12:00:00Z`),'UTC').split(' · ')[0];
  const work=s.work,baseToday=`/dashboard?property=${property.id}`,queueHref=(queue:string,page=1)=>`${baseToday}&queue=${queue}&page=${page}`,selected=todayQueues.find(q=>q.id===work.queue);
  const alerts=[
    ...(s.late_arrivals?[{title:`${s.late_arrivals} missed arrival${s.late_arrivals===1?'':'s'} to follow up`,href:`${base}/reservations?view=all&status=confirmed&to=${new Date(Date.parse(s.day)-86400000).toISOString().slice(0,10)}`}]:[]),
    ...(p.tasks&&s.tasks.overdue?[{title:`${s.tasks.overdue} overdue task${s.tasks.overdue===1?'':'s'}`,href:`${base}/tasks?view=overdue`}]:[]),
    ...(s.channel_failures?[{title:`${s.channel_failures} channel issue${s.channel_failures===1?'':'s'}`,href:`${base}/channels`}]:[])
  ];
  const membership=membershipResult.data?.find(m=>m.tenant_id===property.tenant_id);
  return <WorkspaceFrame platformAccess={!!platformAdmin} properties={properties} property={property} name={name} tenantName={tenant?.name??''} permissions={p} teamAccess={membership?.role==='owner'||membership?.role==='admin'} inboxCount={work.counts.inbox??0}>
    <div className="today-page">
      {(params.error||inviteError)&&<div className="dash-warning" role="alert">{params.error||'We couldn’t check pending invitations. Refresh to try again.'}</div>}
      <header className="today-heading"><div><h1>Today</h1><p>{date} · {property.timezone}</p></div><div className="today-heading-actions"><RefreshDashboard/>{p.book&&<Link className="dash-button" href={`${base}/reservations/new?walkin=1`}>＋ Walk-in / new booking</Link>}</div></header>
      <p className="today-updated">Updated {new Intl.DateTimeFormat('en',{hour:'numeric',minute:'2-digit',timeZone:property.timezone}).format(new Date(s.updated_at))} · Refresh for the latest changes.</p>
      <nav className="today-queues" aria-label="Today’s work">{todayQueues.filter(q=>work.counts[q.id]!==null).map(q=><Link key={q.id} href={queueHref(q.id)} aria-current={q.id===work.queue?'page':undefined} className="today-queue"><span>{q.label}</span><strong>{work.counts[q.id]}</strong><small>{q.id==='documents'?'Stays awaiting review':q.id==='inbox'?'Conversations awaiting a reply':'Remaining stays'}</small></Link>)}</nav>
      <div className="today-summary"><span><strong>{s.tonight.booked} / {s.units}</strong> rooms booked tonight</span>{s.in_house!==undefined&&<span><strong>{s.in_house}</strong> stays in house</span>}{p.finance&&<span><strong>{money(s.collections??0,property.currency)}</strong> collected today{Number(s.refunds_today)>0?` · ${money(s.refunds_today??0,property.currency)} refunded`:''}</span>}{p.reports&&<Link href={`${base}/reports`}>Reports & insights →</Link>}</div>
      {alerts.length>0&&<aside className="today-alerts" aria-label="Follow up">{alerts.map(a=><Link key={a.title} href={a.href}>{a.title} →</Link>)}</aside>}
      <div className="today-columns"><section className="today-card today-work" aria-labelledby="today-work-heading"><header className="today-card-heading"><div><h2 id="today-work-heading">{selected?.label??'Your daily work'}</h2><p>{selected?.description??'Your role does not include reservation or inbox access. Use your available operations below.'}</p></div><span className="today-count">{work.total}</span></header>
        {work.rows.length===0?<div className="today-empty"><strong>{selected?'You’re up to date here.':'No daily queue available.'}</strong><p>{work.queue==='departures'?'Checked-out stays are excluded from this queue.':work.queue==='arrivals'?'Already checked-in guests appear in Reservations → In house.':'New work will appear after you refresh.'}</p></div>:<ul className="today-work-list">{work.rows.map(row=>{
          const stayUrl=`${base}/reservations/${row.id}`,isInbox=work.queue==='inbox',isArrival=work.queue==='arrivals',isDeparture=work.queue==='departures',blocked=isArrival&&(!!row.document_error||!row.room||row.room_active===false||row.room_occupied||row.room_state!=='clean'),balance=row.finance?.checkout_balance;
          return <li key={row.id}><div className="today-work-row"><div className="today-guest"><Link href={isInbox?`${base}/inbox?c=${row.id}`:stayUrl}>{row.full_name||'Guest'}</Link>{isInbox?<><p>{row.preview||'Guest sent a message'}</p><small>{row.human_handoff?'Reception requested · ':''}{row.received_at?displayDateTime(new Date(row.received_at),property.timezone):''}</small></>:<><p>{row.room?`Room ${row.room}`:'Room unassigned'} · {dayLabel(row.check_in!)} – {dayLabel(row.check_out!)}</p><small>{work.queue==='documents'?`${row.pending_documents} uploaded document${row.pending_documents===1?'':'s'} to review`:isArrival?(row.check_in!<s.day?'Late arrival · ':'')+(row.document_error?'Documents need attention':!row.room?'Assign a room':row.room_active===false?'Assigned room is inactive':row.room_occupied?'Previous guest still in room':row.room_state!=='clean'?'Room needs cleaning':'Ready for check-in'):(row.check_out!<s.day?'Overdue departure · ':'')+(balance!==undefined?`Estimated checkout balance ${money(balance,property.currency)}`:'Review settlement before checkout')}</small></>}</div><div className="today-row-actions">
            {isInbox?<Link className="dash-button" href={`${base}/inbox?c=${row.id}`}>Reply</Link>:work.queue==='documents'?<Link className="dash-button" href={`${stayUrl}?tab=documents`}>Review documents</Link>:<>
              {work.can_frontdesk&&(!isArrival||!blocked)&&<TodayStayAction key={row.id+':'+row.version} property={property.id} id={row.id} version={row.version!} name={row.full_name||'Guest'} operation={isArrival?'check_in':'check_out'}/>}
              {isArrival&&blocked?<Link className="dash-button dash-secondary" href={row.document_error&&work.can_review?`${stayUrl}?tab=documents`:stayUrl}>{row.document_error&&work.can_review?'Review documents':'Review stay'}</Link>:<Link className="today-text-link" href={isDeparture&&p.finance?`${stayUrl}?tab=billing`:stayUrl}>{isDeparture&&p.finance?'Review bill':'Open stay'} →</Link>}
            </>}
          </div></div></li>;
        })}</ul>}
        {work.total>6&&<nav className="today-pagination" aria-label="Work queue pages"><span>{(work.page-1)*6+1}–{Math.min(work.page*6,work.total)} of {work.total}</span><div>{work.page>1&&<Link href={queueHref(work.queue,work.page-1)}>← Previous</Link>}{work.page*6<work.total&&<Link href={queueHref(work.queue,work.page+1)}>Next →</Link>}</div></nav>}
      </section><aside className="today-operations">
        <section className="today-card"><header className="today-card-heading"><div><h2>Room readiness</h2><p>Cleanliness and availability are separate.</p></div></header><dl className="today-room-counts"><div><dt>Clean</dt><dd>{s.rooms.clean}</dd></div><div><dt>Cleaning</dt><dd>{s.rooms.in_progress}</dd></div><div><dt>Needs cleaning</dt><dd>{s.rooms.dirty}</dd></div></dl>{s.rooms_to_clean.length>0&&<ul className="today-room-list">{s.rooms_to_clean.map(room=><li key={room.id}><span>Room {room.name}</span><small>{room.housekeeping_status==='dirty'?'Needs cleaning':'Cleaning'}</small></li>)}</ul>}{(p.tasks||p.inventory)&&<Link className="today-card-footer" href={p.tasks?`${base}/tasks?mode=rooms&room_state=attention`:`${base}/inventory`}>Manage room readiness →</Link>}</section>
        {p.tasks&&<section className="today-card"><header className="today-card-heading"><div><h2>Open tasks <span className="today-count">{s.tasks.open}</span></h2></div><Link href={`${base}/tasks`}>View all →</Link></header>{s.task_list.length?<ul className="today-task-list">{s.task_list.map(task=><li key={task.id}><Link href={`${base}/tasks/${task.id}`}><strong>{task.title}</strong><small>{task.priority==='urgent'||task.priority==='high'?`${task.priority} priority · `:''}{task.due_at?`Due ${displayDateTime(new Date(task.due_at),property.timezone)}`:'No due time'}</small></Link></li>)}</ul>:<p className="today-card-note">No open tasks.</p>}</section>}
      </aside></div>
    </div>
  </WorkspaceFrame>;
}

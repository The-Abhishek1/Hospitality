"use client";
import Link from 'next/link';
import { useRef, useState } from 'react';
export type Stay = { id: string; full_name: string | null; room: string | null; status: string; check_in: string; check_out: string; source: string };
const tabs = [{id:'arrivals',label:'Arrivals',view:'arrivals'}, {id:'departures',label:'Departures',view:'departures'}, {id:'inhouse',label:'In house',view:'in_house'}] as const;
type Tab = typeof tabs[number]['id'];
const stayDate = (day:string) => new Intl.DateTimeFormat('en',{day:'numeric',month:'short',timeZone:'UTC'}).format(new Date(`${day}T12:00:00Z`));

export function TodayStays({ stays, day, property, canRead, totals }: { stays: Stay[]; day: string; property: string; canRead: boolean; totals: Record<Tab,number> }) {
  const [tab,setTab] = useState<Tab>('arrivals');
  const buttons=useRef<(HTMLButtonElement|null)[]>([]);
  const rows = stays.filter(s => tab === 'arrivals' ? s.check_in === day : tab === 'departures' ? s.check_out === day && s.status !== 'confirmed' : s.status === 'checked_in');
  const view=tabs.find(t=>t.id===tab)!.view;
  return <section className="overview-card overview-stays" aria-labelledby="overview-guests-title">
    <div className="overview-card-heading"><h2 id="overview-guests-title">Today’s guests</h2>{canRead && <Link href={`/p/${property}/reservations`}>All reservations →</Link>}</div>
    {!canRead ? <p className="overview-note">Reservation details require reservation access.</p> : <>
      <div className="overview-tabs" role="tablist" aria-label="Today’s guests">{tabs.map((t,index) => <button key={t.id} type="button" ref={el=>{buttons.current[index]=el;}} role="tab" id={`tab-${t.id}`} tabIndex={tab===t.id?0:-1} aria-selected={tab===t.id} aria-controls="stay-panel" onClick={() => setTab(t.id)} onKeyDown={event=>{
        const next=event.key==='ArrowRight'?(index+1)%tabs.length:event.key==='ArrowLeft'?(index+tabs.length-1)%tabs.length:event.key==='Home'?0:event.key==='End'?tabs.length-1:null;
        if(next!==null){event.preventDefault();setTab(tabs[next].id);buttons.current[next]?.focus();}
      }}>{t.label} <span>{totals[t.id]}</span></button>)}</div>
      <div role="tabpanel" id="stay-panel" aria-labelledby={`tab-${tab}`} tabIndex={0}>
        {rows.length > 0 ? <ul className="overview-guest-list">{rows.slice(0,6).map(s => <li key={s.id}><Link className="overview-guest" href={`/p/${property}/reservations/${s.id}`}>
          <span className="overview-guest-name"><strong>{s.full_name || 'Guest'}</strong><small>{s.source === 'ota' ? 'Channel booking' : s.source.replaceAll('_',' ')}</small></span>
          <span className="overview-guest-stay"><span>{s.room ? `Room ${s.room}` : 'Room unassigned'}</span><small>{stayDate(s.check_in)} – {stayDate(s.check_out)}</small></span>
          <span className={`overview-status ${s.status}`}>{s.status==='confirmed'?'To check in':s.status.replaceAll('_',' ')}</span>
          <span className="overview-guest-arrow" aria-hidden="true">→</span>
        </Link></li>)}</ul> : <p className="overview-empty">{totals[tab]>0 ? 'Open the full list to see these guests.' : tab==='arrivals' ? 'No arrivals today.' : tab==='departures' ? 'No departures today.' : 'No guests are checked in.'}</p>}
      </div>
      {totals[tab] > 0 && <div className="overview-stays-footer"><span>{Math.min(rows.length,6)} of {totals[tab]} shown</span><Link href={`/p/${property}/reservations?view=${view}`}>View {tab==='inhouse'?'in-house guests':tab==='arrivals'?'arrivals':'departures'} →</Link></div>}
    </>}
  </section>;
}

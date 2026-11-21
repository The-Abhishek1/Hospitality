import Link from "next/link";
import { DistributionCatalog } from "@/components/channels/distribution-catalog";
import { createClient } from "@/lib/supabase/server";
import { connectChannel, mapRoom, resync, prepareChannel, mapRate, saveRates } from "./actions";

import "@/components/service-desk/service-desk.css";
import "./channels.css";

const providers = [{key:"agoda",name:"Agoda",note:"Partner access and sandbox certification required",url:"https://developer.agoda.com/supply/docs/introduction"},{key:"booking_com",name:"Booking.com",note:"Connectivity partner access required; new-provider onboarding is currently paused",url:"https://connect.booking.com/"},{key:"makemytrip",name:"MakeMyTrip / Goibibo",note:"Awaiting official partner API documentation and sandbox access",url:"https://in.goibibo.com/"}];
const providerName = (key:string) => providers.find(p=>p.key===key)?.name ?? "Test channel";

const f = "rounded border border-slate-300 px-2 py-1 text-sm";
const sm = "rounded border border-slate-300 px-2 py-0.5 text-xs hover:bg-slate-100";

export default async function ChannelsPage({
  params, searchParams,
}: { params: Promise<{ propertyId: string }>; searchParams: Promise<{ error?: string }> }) {
  const { propertyId: pid } = await params;
  const { error } = await searchParams;
  const supabase = await createClient();

  const [{ data: conns }, { data: maps }, { data: types }, { data: jobs }, { data: events }, {data: products}, {data: polls}, {data: rates}, {data: rateMaps}, {data: calendar}, {data: property}] = await Promise.all([
    supabase.from("channel_connections").select("id, provider, status, last_sync_at, external_property_id, sandbox_approved").eq("property_id", pid),
    supabase.from("channel_unit_mappings").select("connection_id, type_id, external_room_id").eq("property_id", pid),
    supabase.from("accommodation_types").select("id, name").eq("property_id", pid).order("name"),
    supabase.from("sync_jobs").select("id, connection_id, status, attempts, error, date_from, date_to").eq("property_id", pid).in("status", ["queued", "running", "dead"]).order("created_at", { ascending: false }).limit(20),
    supabase.from("channel_events").select("id, external_event_id, status, error, attempts, payload, received_at").eq("property_id", pid).in("status", ["failed", "dead"]).order("received_at", { ascending: false }).limit(20),
    supabase.from("channel_products").select("connection_id,snapshot,fetched_at").eq("property_id",pid),
    supabase.from("channel_poll_state").select("connection_id,cursor_at,last_success_at,last_error,attempts").eq("property_id",pid),
    supabase.from("rate_plans").select("id,name").eq("property_id",pid).order("name"),
    supabase.from("channel_rate_mappings").select("connection_id,rate_plan_id,external_rate_id").eq("property_id",pid),
    supabase.from("channel_rate_calendar").select("connection_id,day,amount,currency,closed,cta,ctd,min_los,max_los").eq("property_id",pid).order("day").limit(20),
    supabase.from("properties").select("currency,timezone").eq("id",pid).single(),
  ]);
  const typeName = new Map(types?.map((t) => [t.id, t.name]));

  const failed = [conns,maps,types,jobs,events,products,polls,rates,rateMaps,calendar].some(x=>x===null);
  const today=property?new Intl.DateTimeFormat('en-CA',{timeZone:property.timezone,year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date()):new Date().toISOString().slice(0,10);
  return (
    <div className="service-workspace channels-workspace">
      <div className="sr-toolbar"><div><span className="sr-live-dot"/>Distribution workspace<small>Map hotel inventory, prepare connections and monitor delivery.</small></div><Link className="dash-button" href={`/p/${pid}/channels/review`}>Review reservation imports →</Link></div>
      {failed && <p role="alert">Channel data could not be loaded. Refresh or ask your hotel administrator for access.</p>}
      <div id="channel-setup" className="channel-provider-grid">{providers.map(p=>{const c=conns?.find(c=>c.provider===p.key);return <section className="channel-card" key={p.key}>
        <span className="sr-eyebrow">{c?.sandbox_approved ? "Sandbox testing" : c ? "Setup saved · paused" : "Not connected"}</span><h2>{p.name}</h2><p>{p.note}</p><a href={p.url} target="_blank" rel="noreferrer">Partner documentation ↗</a>
        <form action={prepareChannel}><input type="hidden" name="pid" value={pid}/><input type="hidden" name="provider" value={p.key}/>
          <label>Provider hotel ID<input className={f} name="hotel" defaultValue={c?.external_property_id??""} inputMode="numeric" pattern="[1-9][0-9]{0,19}" required/></label>
          <label>Server credential reference (optional)<input className={f} name="reference" placeholder="Configured by your platform operator" pattern="[-a-zA-Z0-9_:]{1,100}"/></label>
          <small>Enter a reference name only. Never paste an API key or password.</small><button className="dash-button">{c?"Update setup and pause":"Save connection setup"}</button>
        </form></section>;})}</div>
      {error && <p className="rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}
      <p className="channel-notice">Agoda sandbox development now includes products, nightly rates and restrictions, and reservation polling. Only eligible single-room Property Collect snapshots import automatically; other cases require review. Provider validation and certification are pending. Booking.com remains availability-only. Saving setup does not enable OTA traffic.</p>

      <section>
        <h2 className="mb-2 font-medium">Connections</h2>
        {!conns?.some(c=>c.provider === "mock") && (
          <form action={connectChannel} className="flex gap-2">
            <input type="hidden" name="pid" value={pid} />
            <select name="provider" className={f}><option value="mock">mock</option></select>
            <button className="rounded bg-slate-900 px-3 py-1 text-sm text-white">Connect</button>
          </form>
        )}
        {conns?.map((c) => (
          <div key={c.id} className="mb-3 space-y-2 rounded-md border bg-white p-3 text-sm">
            <div className="flex items-center justify-between">
              <span><b>{providerName(c.provider)}</b> <span className="text-xs text-slate-500">{c.status} · last accepted availability update {c.last_sync_at ? c.last_sync_at.slice(0, 16).replace("T", " ") : "never"}</span></span>
              <form action={resync}><input type="hidden" name="pid" value={pid} /><input type="hidden" name="connection" value={c.id} /><button className={sm}>Queue availability sync</button></form>
            </div>
            <ul className="text-xs text-slate-600">
              {maps?.filter((m) => m.connection_id === c.id).map((m) => <li key={m.type_id}>{typeName.get(m.type_id)} → <code>{m.external_room_id}</code></li>)}
            </ul>
            <form action={mapRoom} className="flex flex-wrap gap-2">
              <input type="hidden" name="pid" value={pid} /><input type="hidden" name="connection" value={c.id} />
              <select aria-label="Hotel room type" name="type" className={f}>{types?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select>
              <input name="external" aria-label="Provider room ID" placeholder="Provider room ID" maxLength={20} required className={f} />
              <button className={sm}>Save room mapping</button>
            </form>
          </div>
        ))}
      </section>

      {conns?.filter(c=>c.provider==='agoda').map(c=>{
        const product=products?.find(p=>p.connection_id===c.id),poll=polls?.find(p=>p.connection_id===c.id);
        const snapshot=product?.snapshot as {currency:string;occupancyModel:string;rooms:{id:string;name:string;minRate:string;maxRate:string}[];rates:{id:string;name:string;master:string;rateType:string;taxIncluded:boolean}[]}|undefined;
        return <section key={c.id} className="agoda-operations"><span className="sr-eyebrow">Agoda · sandbox development</span><h2>Products, rates & reservation retrieval</h2>
          <div className="agoda-health"><p><strong>Product discovery</strong><span>{product?`Updated ${new Date(product.fetched_at).toLocaleString()}`:'Awaiting approved sandbox access and worker connection'}</span></p><p><strong>Reservation polling</strong><span>{poll?.last_success_at?`Last retrieved ${new Date(poll.last_success_at).toLocaleString()}`:'No successful retrieval yet'}</span>{poll&&<small>Checkpoint: {new Date(poll.cursor_at).toLocaleString()} · {poll.attempts} consecutive failures</small>}</p></div>
          {poll?.last_error&&<p role="alert" className="channel-notice">Reservation retrieval needs attention: {poll.last_error}</p>}
          {snapshot?<><p>Provider currency: <b>{snapshot.currency}</b> · Occupancy model: {snapshot.occupancyModel}. Verify the correct NET/SELL and tax basis for every rate before publishing.</p>
          <div className="sr-table-scroll"><table className="sr-table"><thead><tr><th>Agoda room ID</th><th>Room</th><th>Provider price limits</th></tr></thead><tbody>{snapshot.rooms.map(r=><tr key={r.id}><td>{r.id}</td><td>{r.name}</td><td>{r.minRate}–{r.maxRate} {snapshot.currency}</td></tr>)}</tbody></table></div>
          <form action={mapRate} className="agoda-rate-form"><h3>Map a rate plan</h3><input type="hidden" name="pid" value={pid}/><input type="hidden" name="connection" value={c.id}/>
          <label>Hotel rate plan<select name="rate" required>{rates?.map(r=><option key={r.id} value={r.id}>{r.name}</option>)}</select></label>
          <label>Agoda master rate<select name="external" required>{snapshot.rates.filter(r=>r.master==='0').map(r=><option key={r.id} value={r.id}>{r.name} ({r.id}) · {r.rateType} · tax {r.taxIncluded?'included':'excluded'}</option>)}</select></label><button className="dash-button">Save rate mapping</button></form>
          <ul className="agoda-mappings">{rateMaps?.filter(m=>m.connection_id===c.id).map(m=><li key={m.rate_plan_id}>{rates?.find(r=>r.id===m.rate_plan_id)?.name} → Agoda rate {m.external_rate_id}</li>)}</ul>
          <form action={saveRates} className="agoda-rate-form"><h3>Set nightly prices & restrictions</h3><input type="hidden" name="pid" value={pid}/><input type="hidden" name="connection" value={c.id}/>
          <label>Mapped room type<select name="type" required>{types?.filter(t=>maps?.some(m=>m.connection_id===c.id&&m.type_id===t.id)).map(t=><option key={t.id} value={t.id}>{t.name}</option>)}</select></label>
          <label>Mapped rate plan<select name="rate" required>{rates?.filter(r=>rateMaps?.some(m=>m.connection_id===c.id&&m.rate_plan_id===r.id)).map(r=><option key={r.id} value={r.id}>{r.name}</option>)}</select></label>
          <label>First night<input name="from" type="date" min={today} required/></label><label>End date (exclusive)<input name="to" type="date" min={today} required/></label>
          <label>Nightly amount ({property?.currency})<input name="amount" type="number" min="0.01" max="999999999" step="0.01" required/></label>
          {([['closed','Stop sell'],['cta','Closed to arrival'],['ctd','Closed to departure']] as const).map(([key,label])=><label key={key}>{label}<select name={key}><option value="">Leave provider setting unchanged</option><option value="true">Yes</option><option value="false">No</option></select></label>)}
          <label>Minimum nights (optional)<input name="min" type="number" min="1" max="99"/></label><label>Maximum nights (0 removes limit)<input name="max" type="number" min="0" max="99"/></label>
          <p>Dates use {property?.timezone}. Amounts use the provider rate’s NET/SELL and tax basis. Saving queues a sandbox update; it does not confirm the rate is bookable.</p><button className="dash-button">Save and queue sandbox update</button></form>
          {!!calendar?.length&&<details><summary>Upcoming calendar entries (first 20)</summary><div className="sr-table-scroll"><table className="sr-table"><thead><tr><th>Night</th><th>Price</th><th>Stop sell</th><th>Arrival / departure closed</th><th>Stay limits</th></tr></thead><tbody>{calendar.filter(r=>r.connection_id===c.id).map((r,i)=><tr key={i}><td>{r.day}</td><td>{r.amount} {r.currency}</td><td>{r.closed===null?'Unchanged':r.closed?'Yes':'No'}</td><td>{r.cta===null?'Unchanged':r.cta?'Yes':'No'} / {r.ctd===null?'Unchanged':r.ctd?'Yes':'No'}</td><td>{r.min_los??'Unchanged'} / {r.max_los??'Unchanged'}</td></tr>)}</tbody></table></div></details>}
          </>:<p>Products must be retrieved from an authorized Agoda sandbox before rate mapping and price publication are available.</p>}
        </section>;
      })}
      <DistributionCatalog/>

      <section>
        <h2 className="mb-2 font-medium">Needs attention</h2>
        <ul className="divide-y rounded-md border bg-white text-sm">
          {jobs?.filter((j) => j.status === "dead").length === 0 && events?.length === 0 && <li className="p-3 text-slate-500">Nothing failing. {jobs?.filter((j) => j.status !== "dead").length ?? 0} sync job(s) in flight.</li>}
          {jobs?.filter((j) => j.status === "dead").map((j) => (
            <li key={j.id} className="p-3"><b className="text-red-700">Sync dead-lettered</b> <span className="text-xs text-slate-500">{j.date_from} → {j.date_to} · {j.attempts} attempts · {j.error}</span></li>
          ))}
          {events?.map((e) => (
            <li key={e.id} className="p-3"><b className={e.status === "dead" ? "text-red-700" : "text-amber-700"}>Inbound event {e.status}</b>{" "}
              <span className="text-xs text-slate-500">{(e.payload as any)?.type} {(e.payload as any)?.external_reservation_id} · attempt {e.attempts} · {e.error}</span></li>
          ))}
        </ul>
        <p className="mt-1 text-xs text-slate-500">Failed imports need review: check room mappings, inventory and the provider reservation before taking action.</p>
      </section>
    </div>
  );
}

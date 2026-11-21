// Publish inventory/rates, poll Agoda snapshots and process the durable event inbox.
// Source events/checkpoints are acknowledged only after durable ingest; retries live in SQL.
// SUPABASE_SERVICE_ROLE_KEY and provider credentials belong only in this server worker.
import { persistChannelEvent } from "./inbox.js";
import { createClient } from "@supabase/supabase-js";
import { AgodaAdapter, type AgodaRatePush } from "./adapters/agoda.js";
import type { ChannelAdapter } from "./adapter.js";
import { supplyRegistry } from "./providers.js";
import { MockAdapter } from "./adapters/mock.js";

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
const adapters = new Map<string, ChannelAdapter>([["mock", new MockAdapter(db)]]);   // supply registry below is sandbox-gated

const supply = supplyRegistry(process.env.CHANNEL_CREDENTIALS_JSON ?? "{}", process.env.CHANNEL_SANDBOX_ENABLED === "true");
const adapterFor = (provider: string, ref: string | null) => adapters.get(provider) ?? supply(provider, ref);

type Job = {
  job_id: string; connection_id: string; provider: string; credentials_ref: string | null;
  type_id: string; external_room_id: string; date_from: string; date_to: string; attempt: number; lease_token: string; external_property_id: string | null; environment: string;
};

async function syncTick(): Promise<number> {
  const { data, error } = await db.rpc("claim_sync_jobs_v2", { p_limit: 1 });
  if (error) throw error;
  const jobs = (data ?? []) as Job[];
  for (const job of jobs) {
    try {
      const adapter = adapterFor(job.provider, job.credentials_ref);
      if (!adapter) throw new Error(`no adapter for provider ${job.provider}`);
      // Compute truth from the database at push time, so coalesced/stale jobs can never push stale numbers.
      const { data: rows, error: e } = await db.rpc("channel_availability_range", { p_connection: job.connection_id, p_from: job.date_from, p_to: job.date_to });
      if (e) throw e;
      const days = ((rows ?? []) as { external_room_id: string; day: string; available: number }[])
        .filter((r) => r.external_room_id === job.external_room_id).map((r) => ({ day: r.day, available: r.available }));
      await adapter.pushAvailability({ connectionId: job.connection_id, credentialsRef: job.credentials_ref, externalPropertyId: job.external_property_id, environment: job.environment }, { externalRoomId: job.external_room_id, days });
      if (adapter instanceof AgodaAdapter) {
        const ctx = {connectionId:job.connection_id,credentialsRef:job.credentials_ref,externalPropertyId:job.external_property_id,environment:job.environment};
        const {data: rates,error: re} = await db.rpc("channel_rates_range",{p_connection:job.connection_id,p_type:job.type_id,p_from:job.date_from,p_to:job.date_to});
        if(re) throw new Error("Could not read channel rate calendar");
        if(rates?.length) {
          const products = await adapter.fetchProducts(ctx);
          for(const push of rates as AgodaRatePush[]) await adapter.pushRates(ctx,push,products);
        }
      }
      const { error: ce } = await db.rpc("complete_sync_job_v2", { p_id: job.job_id, p_lease: job.lease_token, p_ok: true });
      if (ce) throw new Error("Could not persist sync completion");
    } catch (err) {
      const { error: ce } = await db.rpc("complete_sync_job_v2", { p_id: job.job_id, p_lease: job.lease_token, p_ok: false, p_error: String((err as Error).message).slice(0, 500) });
      if (ce) console.error("Could not persist failed sync attempt");
    }
  }
  return jobs.length;
}

async function eventsTick(): Promise<number> {
  const { data: conns, error } = await db.from("channel_connections").select("id, provider, credentials_ref").eq("status", "active").eq("provider", "mock");
  if (error) throw error;
  let ingested = 0;
  for (const c of conns ?? []) {
    const adapter = adapters.get(c.provider);
    if (!adapter) continue;
    try {
      for (const ev of await adapter.fetchEvents({ connectionId: c.id, credentialsRef: c.credentials_ref })) {
        // Source event stays available until our durable inbox has accepted it.
        await persistChannelEvent(db,c.id,ev);
        await adapter.acknowledgeEvent?.({connectionId:c.id,credentialsRef:c.credentials_ref},ev);
        ingested++;
      }
    } catch (err) { console.error(`events for ${c.provider} failed`, err); }
  }
  const { data: processed, error: pe } = await db.rpc("process_pending_channel_events", { p_limit: 50 });
  if (pe) throw pe;
  return ingested + Number(processed ?? 0);
}

async function agodaPollTick(): Promise<number> {
  if(process.env.CHANNEL_SANDBOX_ENABLED !== 'true') return 0;
  const {data:poll,error} = await db.rpc('claim_channel_poll');
  if(error) throw new Error('Could not claim Agoda polling window');
  if(!poll) return 0;
  try {
    const adapter=adapterFor('agoda',poll.credentialsRef);
    if(!(adapter instanceof AgodaAdapter)) throw new Error('Agoda adapter unavailable');
    const products=await adapter.fetchProducts(poll);
    const {error: productError}=await db.rpc('save_channel_products',{p_connection:poll.connectionId,p_snapshot:products});
    if(productError) throw new Error('Could not save Agoda product catalog');
    const events=await adapter.fetchReservationWindow(poll,poll.from,poll.to);
    for(const event of events) {
      await persistChannelEvent(db,poll.connectionId,event);
    }
    const {data: completed,error: ce}=await db.rpc('complete_channel_poll',{p_connection:poll.connectionId,p_lease:poll.lease,p_to:poll.to,p_ok:true});
    if(ce||!completed)throw new Error('Agoda polling lease expired; window will be retried');
  } catch(e) {
    const {error: ce}=await db.rpc('complete_channel_poll',{p_connection:poll.connectionId,p_lease:poll.lease,p_to:poll.to,p_ok:false,p_error:e instanceof Error?e.message:'Agoda polling failed'});
    if(ce)console.error('Could not persist Agoda poll failure');
  }
  return 1;
}

for (;;) {
  let busy = 0;
  try { busy += await syncTick(); busy += await agodaPollTick(); busy += await eventsTick(); } catch (e) { console.error("tick failed", e); }
  if (busy === 0) await new Promise((r) => setTimeout(r, 3000));
}

// Supabase Edge Function (Deno). Receives WhatsApp Cloud API webhooks.
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (server-side only), WHATSAPP_APP_SECRET, WHATSAPP_VERIFY_TOKEN.
// Deploy with JWT verification off (Meta cannot send a Supabase JWT); authenticity comes from the HMAC signature below.
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const APP_SECRET = Deno.env.get("WHATSAPP_APP_SECRET")!;
const VERIFY_TOKEN = Deno.env.get("WHATSAPP_VERIFY_TOKEN")!;
const enc = new TextEncoder();

async function validSignature(raw: string, header: string | null): Promise<boolean> {
  if (!header?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(APP_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(raw)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  const given = header.slice(7);
  if (given.length !== expected.length) return false;
  let diff = 0; // constant-time compare
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // Meta's one-time subscription handshake.
  if (req.method === "GET") {
    if (url.searchParams.get("hub.mode") === "subscribe" && url.searchParams.get("hub.verify_token") === VERIFY_TOKEN) {
      return new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 });
    }
    return new Response("forbidden", { status: 403 });
  }
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const raw = await req.text();
  if (!(await validSignature(raw, req.headers.get("x-hub-signature-256")))) return new Response("invalid signature", { status: 401 });

  try {
    const body = JSON.parse(raw);
    if (body.object !== 'whatsapp_business_account') return new Response('ok', {status:200});
    for (const entry of body.entry ?? []) {
      for (const change of entry.changes ?? []) {
        const v = change.value ?? {};
        if (change.field === 'account_update' && ['PARTNER_REMOVED', 'ACCOUNT_OFFBOARDED'].includes(v.event)) {
          const at=Number(entry.time);
          const { error } = await db.rpc('whatsapp_coexistence_account_update', { p_waba: v.waba_info?.waba_id ?? entry.id, p_event: v.event, ...(Number.isFinite(at)&&at>0?{p_at:new Date(at*1000).toISOString()}: {}) });
          if (error) throw error;
          continue;
        }
        const phoneNumberId: string | undefined = v.metadata?.phone_number_id;
        if (!phoneNumberId) continue;
        if (['history', 'smb_app_state_sync', 'smb_message_echoes'].includes(change.field)) {
          const { error } = await db.rpc('enqueue_whatsapp_coexistence', { p_phone: phoneNumberId, p_waba: entry.id, p_field: change.field, p_payload: v });
          if (error) throw error;
          const wake = await db.rpc('wake_whatsapp_coexistence');
          if (wake.error) throw wake.error;
          continue;
        }
        const names = new Map<string, string>((v.contacts ?? []).map((c: any) => [c.wa_id, c.profile?.name]));

        for (const m of v.messages ?? []) {
          // This includes late media chunks, edits and revokes. They must not open
          // a new service window or replay an old guest command.
          const routed=await db.rpc('route_whatsapp_coexistence_message',{p_phone:phoneNumberId,p_waba:entry.id,p_payload:m});
          if(routed.error)throw routed.error;
          if (routed.data) {
            const wake=await db.rpc('wake_whatsapp_coexistence');if(wake.error)throw wake.error;
            continue;
          }
          if (['edit','revoke'].includes(m.type)) continue;
          if (!m.from || !m.id || !Number.isFinite(Number(m.timestamp))) continue;
          const text = m.type === "text" ? m.text?.body ?? "" : `[${m.type}]`;
          const { error } = await db.rpc("ingest_whatsapp_inbound", {
            p_phone_number_id: phoneNumberId, p_event_key: `msg:${m.id}`, p_wa_contact_id: m.from,
            p_contact_name: names.get(m.from) ?? null, p_wa_message_id: m.id, p_type: m.type, p_body: text,
            p_payload: m, p_sent_at: new Date(Number(m.timestamp) * 1000).toISOString(),
          });
          if (error) throw error;
        }
        for (const s of v.statuses ?? []) {
          const { error } = await db.rpc("ingest_whatsapp_status", {
            p_phone_number_id: phoneNumberId, p_event_key: `st:${s.id}:${s.status}`, p_wa_message_id: s.id,
            p_status: s.status, p_error: s.errors?.[0]?.title ?? null,
          });
          if (error) throw error;
        }
      }
    }
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error("webhook processing failed"); // Never log guest payloads, tokens or raw provider errors.
    return new Response("error", { status: 500 }); // Meta retries; the database dedupes, so retries are safe
  }
});

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
    for (const entry of body.entry ?? []) {
      for (const change of entry.changes ?? []) {
        const v = change.value ?? {};
        const phoneNumberId: string | undefined = v.metadata?.phone_number_id;
        if (!phoneNumberId) continue;
        const names = new Map<string, string>((v.contacts ?? []).map((c: any) => [c.wa_id, c.profile?.name]));

        for (const m of v.messages ?? []) {
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
    console.error("webhook processing failed", e);
    return new Response("error", { status: 500 }); // Meta retries; the database dedupes, so retries are safe
  }
});

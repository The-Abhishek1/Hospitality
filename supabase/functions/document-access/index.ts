// Staff-facing: returns a 60-second signed URL for a guest document AFTER the database authorises and audits the access.
// Called with the staff member's JWT; deploy with gateway JWT verification ON.
// PostgREST also validates the JWT and the scoped RPC checks permission and records access.
// The service-role key never leaves this function.
import { createClient } from "npm:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

Deno.serve(async (req) => {
  const auth = req.headers.get("Authorization");
  if (!auth) return new Response("unauthorized", { status: 401 });
  const { document_id, reason } = await req.json().catch(() => ({}));

  // Run the permission check + audit insert as the caller, not as the service role.
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: path, error } = await asUser.rpc("authorize_document_access", { p_doc: document_id, p_reason: reason });
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: error.code === "42501" ? 403 : 400 });

  const signed = await admin.storage.from("guest-documents").createSignedUrl(path, 60);
  if (signed.error) return new Response(JSON.stringify({ error: "could not sign URL" }), { status: 500 });
  return new Response(JSON.stringify({ url: signed.data.signedUrl, expires_in: 60 }), { headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
});

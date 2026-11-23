// Guest-facing document upload (Deno edge function). Deploy with --no-verify-jwt: the guest has no Supabase account;
// the secret portal link token is the credential, validated inside portal_prepare_document / portal_confirm_document.
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (server-side only), PORTAL_ORIGIN (CORS allow-list).
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const BUCKET = "guest-documents";
const cors = {
  "Access-Control-Allow-Origin": Deno.env.get("PORTAL_ORIGIN") ?? "",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let b: any;
  try { b = await req.json(); } catch { return json({ error: "invalid json" }, 400); }

  if (b.action === "prepare") {
    const { data, error } = await db.rpc("portal_prepare_document", { p_token: b.token, p_doc_type: b.doc_type, p_mime: b.mime, p_size: b.size });
    if (error) return json({ error: error.message }, error.code === "28000" ? 401 : 400);
    const signed = await db.storage.from(BUCKET).createSignedUploadUrl(data.storage_path);
    if (signed.error) return json({ error: "could not create upload URL" }, 500);
    return json({ document_id: data.document_id, path: signed.data.path, upload_token: signed.data.token });
  }

  if (b.action === "confirm") {
    const { data: doc, error: scopeError } = await db.rpc("portal_upload_metadata", { p_token: b.token, p_doc: b.document_id });
    if (scopeError || !doc) return json({ error: "Document unavailable for this stay." }, scopeError?.code === "28000" ? 401 : 400);
    // Fail closed: only confirm if the object really exists and matches the declared size.
    const slash = doc.storage_path.lastIndexOf("/");
    const { data: files } = await db.storage.from(BUCKET).list(doc.storage_path.slice(0, slash), { search: doc.storage_path.slice(slash + 1) });
    const f = files?.find((x) => x.name === doc.storage_path.slice(slash + 1));
    if (!f || Number(f.metadata?.size) !== doc.size_bytes || f.metadata?.mimetype !== doc.mime_type) return json({ error: "upload not found or size mismatch" }, 400);
    const { error } = await db.rpc("portal_confirm_document", { p_token: b.token, p_doc: b.document_id });
    if (error) return json({ error: error.message }, error.code === "28000" ? 401 : 400);
    return json({ ok: true }); // Remains private until the configured image processor or antivirus worker finishes.
  }
  return json({ error: "unknown action" }, 400);
});

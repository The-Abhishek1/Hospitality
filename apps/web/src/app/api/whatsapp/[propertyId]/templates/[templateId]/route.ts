import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { backend, savedToken, meta, SetupError } from '@/lib/whatsapp-onboarding';
export const runtime = 'nodejs';
export const maxDuration = 60;
const reply = (body: object, status = 200) => NextResponse.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
type Params = { params: Promise<{ propertyId: string; templateId: string }> };
async function access(params: Params['params']) {
  const { propertyId: pid, templateId: tid } = await params;
  if (![pid, tid].every(id => /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id))) return { response: reply({ error: 'Invalid hotel or template.' }, 400) };
  const db = await createClient(), { data: { user } } = await db.auth.getUser();
  if (!user) return { response: reply({ error: 'Sign in again.' }, 401) };
  const result = await db.rpc('whatsapp_template_deletion_context', { p_property: pid, p_template: tid });
  if (result.error) return { response: reply({ error: result.error.code === 'P0002' ? 'Template not found for this hotel.' : 'Hotel administrator access is required for this active hotel.' }, result.error.code === 'P0002' ? 404 : 403) };
  return { pid, tid, db, context: result.data };
}
export async function GET(_req: NextRequest, { params }: Params) {
  const a = await access(params);
  return a.response ?? reply(a.context);
}
export async function DELETE(req: NextRequest, { params }: Params) {
  if (req.headers.get('origin') !== (process.env.WHATSAPP_ONBOARDING_ORIGIN || req.nextUrl.origin)) return reply({ error: 'Open the configured hotel app address.' }, 403);
  const a = await access(params);
  if (a.response) return a.response;
  let input: { provider_id?: string; confirm_name?: string; confirm_language?: string };
  try {
    if (Number(req.headers.get('content-length')) > 2000) return reply({ error: 'Deletion confirmation is too large.' }, 413);
    const raw = await req.text();
    if (raw.length > 2000) return reply({ error: 'Deletion confirmation is too large.' }, 413);
    input = JSON.parse(raw);
    if (!input || Array.isArray(input) || !['provider_id', 'confirm_name', 'confirm_language'].every(key => typeof input[key as keyof typeof input] === 'string')) throw Error();
  } catch { return reply({ error: 'Review the template and type its name to confirm deletion.' }, 400); }
  const prepared = await a.db!.rpc('begin_whatsapp_template_deletion', { p_property: a.pid, p_template: a.tid, p_provider_id: input.provider_id, p_confirm_name: input.confirm_name, p_confirm_language: input.confirm_language });
  if (prepared.error) return reply({ error: ['22023', '40001'].includes(prepared.error.code) ? prepared.error.message : 'Could not confirm deletion. Refresh the template library.' }, 409);
  if (prepared.data.already_deleted) return reply({ success: 'This template is already deleted.', deleted: true });
  const job = prepared.data;
  const finish = async (outcome: string) => backend().rpc('finish_whatsapp_template_deletion', { p_operation: job.operation, p_outcome: outcome });
  let accepted = false;
  try {
    const token = await savedToken(`managed:${a.pid}`);
    // Name + ID deletes just the selected language, never every translation of a name.
    const query = new URLSearchParams({ hsm_id: job.provider_id, name: job.name });
    const result = await meta(`${job.waba_id}/message_templates?${query}`, token, 'DELETE', undefined, 'template');
    if (result.success !== true) throw Error('Unconfirmed provider result');
    accepted = true;
    const completed = await finish('deleted');
    if (completed.error || completed.data !== true) throw Error('Local confirmation unavailable');
    return reply({ success: `Meta accepted deletion of ${job.name} (${job.language}). Removed from the library; message history is retained.`, deleted: true });
  } catch (error) {
    // A timeout may happen after Meta accepted the request. Retain the reservation
    // and reconcile via full sync instead of claiming success or deleting again.
    const definitive = !accepted && error instanceof SetupError && (error.httpStatus ?? 400) < 500;
    await finish(definitive ? 'failed' : 'uncertain').catch(() => null);
    return reply({ error: definitive ? error.message : 'Deletion could not be fully confirmed. Check approval & sync before trying again; the template is held from new sending until its status is checked.', uncertain: !definitive }, definitive ? 400 : 502);
  }
}

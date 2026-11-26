import {NextRequest, NextResponse} from 'next/server';
import {createClient as createAuthClient} from '@supabase/supabase-js';
import {createClient} from '@/lib/supabase/server';
import {backend} from '@/lib/whatsapp-onboarding';
import {validId} from '@/lib/reservations';
export const runtime = 'nodejs';
export const maxDuration = 60;
const reply = (body: object, status = 200) => NextResponse.json(body, {status, headers: {'Cache-Control': 'private, no-store'}});
const safeError = (error: {code?: string; message: string}) => ['22023', '40001', '55000', 'P0002'].includes(error.code || '') ? error.message : 'Could not complete cleanup. The business remains frozen; retry or contact platform support.';
export async function POST(req: NextRequest, {params}: {params: Promise<{tenantId: string}>}) {
  if (req.headers.get('origin') !== (process.env.APP_URL || req.nextUrl.origin).replace(/\/$/, '')) return reply({error: 'Open the configured hotel app address.'}, 403);
  const {tenantId} = await params;
  if (!validId(tenantId)) return reply({error: 'Business account not found.'}, 404);
  if (Number(req.headers.get('content-length')) > 8192) return reply({error: 'Request is too large.'}, 413);
  const db = await createClient();
  const {data: {user}} = await db.auth.getUser();
  if (!user) return reply({error: 'Sign in again.'}, 401);
  const {data: admin, error: accessError} = await db.from('platform_admins').select('user_id').eq('user_id', user.id).maybeSingle();
  if (accessError || !admin) return reply({error: 'Platform administrator access required.'}, 403);
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) return reply({error: 'Platform deletion is not configured.'}, 503);
  try {
    const input = await req.json();
    if (input.action === 'begin') {
      if (!validId(input.request) || !Number.isInteger(input.version) || typeof input.name !== 'string' || input.name.length > 300 || typeof input.reason !== 'string' || input.reason.trim().length < 5 || input.reason.length > 1000 || typeof input.password !== 'string' || input.password.length > 256 || input.acknowledged !== true) return reply({error: 'Complete the business name, reason, password and deletion acknowledgment.'}, 400);
      // Separate client: verifying a password must not replace the administrator's session cookies.
      const verifier = createAuthClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {auth: {persistSession: false, autoRefreshToken: false}});
      const verified = await verifier.auth.signInWithPassword({email: user.email!, password: input.password});
      if (verified.error || verified.data.user?.id !== user.id) return reply({error: 'Your admin password could not be verified.'}, 403);
      const {data: job, error} = await backend().rpc('platform_business_deletion_begin', {p_tenant: tenantId, p_actor: user.id, p_request: input.request, p_version: input.version, p_name: input.name, p_reason: input.reason});
      if (error) return reply({error: safeError(error)}, 409);
      return reply({job});
    }
    if (input.action !== 'continue' || !validId(input.job)) return reply({error: 'Choose a valid deletion request.'}, 400);
    // Bind the job to the URL business before any Storage operation.
    const context = await db.rpc('platform_business_deletion_preview', {p_tenant: tenantId});
    if (context.error || context.data?.job !== input.job) return reply({error: 'Deletion request not found for this business.'}, 404);
    const adminDb = backend();
    const {data, error} = await adminDb.rpc('platform_business_deletion_step', {p_job: input.job, p_actor: user.id});
    if (error) return reply({error: safeError(error)}, 409);
    if (data.state === 'complete') return reply({state: 'complete'});
    if (data.state === 'hotels') return reply({state: 'hotels', remaining: data.remaining, total: data.total, completed: data.completed});
    const files = data.files as {bucket: string; path: string}[];
    for (const bucket of new Set(files.map(file => file.bucket))) {
      const removed = await adminDb.storage.from(bucket).remove(files.filter(file => file.bucket === bucket).map(file => file.path));
      if (removed.error) return reply({error: 'Uploaded files could not be removed. The business remains frozen. Resume deletion to retry.'}, 503);
    }
    // A following request rechecks actual Storage metadata before deleting any database rows.
    return reply({state: 'files', hotel: data.hotel, remaining: Math.max(0, data.remaining - files.length)});
  } catch {
    return reply({error: 'Deletion was interrupted. Refresh this page to check its status and resume.'}, 400);
  }
}

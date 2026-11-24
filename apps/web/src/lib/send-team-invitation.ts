import 'server-only';
import { createClient as createBackend } from '@supabase/supabase-js';
import { createClient } from '@/lib/supabase/server';
import { sendInvitationEmail, teamEmailConfig, type InvitationEmailContext } from '@/lib/team-email';

export async function deliverTeamInvitation(tid: string, invitation: string, version: number, request: string): Promise<{ status: string; error?: string }> {
 try {
  const config = teamEmailConfig();
  if (!config) return { status: 'unconfigured' };
  const db = await createClient();
  const { data: claim, error } = await db.rpc('team_invitation_email_start', { p_tenant: tid, p_invitation: invitation, p_request: request, p_version: version });
  if (error) return { status: 'blocked', error: ['22023', '40001', 'P0002'].includes(error.code) ? error.message : 'Your business role does not permit sending this invitation.' };
  if (!claim.send) return { status: claim.status };
  const result = await sendInvitationEmail(claim.context as InvitationEmailContext, claim.delivery_id, config);
  const backend = createBackend(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error: saveError } = await backend.rpc('team_invitation_email_finish', { p_delivery: claim.delivery_id, p_status: result.status, p_provider_id: result.providerId ?? null, p_error: result.error ?? null });
  return { status: saveError ? 'unknown' : result.status };
 } catch {
   // Preserve the invitation even if transport or result recording is interrupted.
   // A committed email claim prevents replay from submitting another email.
   return { status: 'unknown' };
 }
}

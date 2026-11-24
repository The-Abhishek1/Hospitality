import Link from 'next/link';
import { randomUUID } from 'node:crypto';
import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { WorkspaceLayout } from '@/components/workspace/layout';
import { TeamFrame } from '@/components/team/frame';
import { InvitationControls, CopyInvitation, SendInvitationEmail } from '@/components/team/invitation-controls';
import { PermissionPreview } from '@/components/team/permissions';
import { TeamHistory } from '@/components/team/team-history';
import { validId } from '@/lib/reservations';
import { serviceTime } from '@/lib/service-desk';
import { businessRoleLabel, invitationLabel, invitationEmailLabel, invitationEmailError, type InvitationDetail, type InvitationEmailDelivery } from '@/lib/team';
import { teamEmailConfig } from '@/lib/team-email';
import '@/components/service-desk/service-desk.css';
import '@/components/team/team.css';
export const metadata = { title: 'Staff invitation · Hospitality' };
export default async function InvitationPage({ params, searchParams }: { params: Promise<{ tenantId: string; invitationId: string }>; searchParams: Promise<{ property?: string; notice?: string; email?: string }> }) {
  const { tenantId: tid, invitationId } = await params, p = await searchParams;
  if (!validId(tid) || !validId(invitationId)) notFound();
  const db = await createClient();
  const [{ data, error }, emailResult] = await Promise.all([
    db.rpc('team_invitation_detail', { p_tenant: tid, p_id: invitationId }),
    db.from('staff_invitation_email_latest').select('*').eq('tenant_id', tid).eq('invitation_id', invitationId).maybeSingle(),
  ]);
  if (error?.code === 'P0002') notFound();
  if (error || !data) return <WorkspaceLayout tenantId={tid}><section><h2>Invitation unavailable</h2><Link href="/dashboard">Back to Today</Link></section></WorkspaceLayout>;
  const d = data as InvitationDetail, i = d.invitation, property = d.properties.find(pr => pr.id === p.property) ?? d.properties[0], pid = property?.id ?? '', tz = property?.timezone ?? 'UTC';
  const delivery = emailResult.data as InvitationEmailDelivery | null, emailReady = !!teamEmailConfig(), valid = i.state === 'pending';
  return <TeamFrame tid={tid} properties={d.properties} property={pid}><div className="service-workspace team-workspace">
    <div className="sr-subheading"><div><Link href={`/t/${tid}/team?mode=invitations&property=${pid}`}>← Invitations</Link><h2>{i.email}</h2><p>{businessRoleLabel(i.tenant_role)}</p></div><span className={`sr-status ${i.state === 'accepted' ? 'completed' : i.state === 'revoked' ? 'cancelled' : i.state === 'expired' ? 'expired' : 'new'}`}>{invitationLabel(i.state)}</span></div>
    {['created', 'renew', 'revoke'].includes(p.notice ?? '') && <p className="sr-alert success" role="status">{p.notice === 'created' ? 'Invitation created.' : p.notice === 'renew' ? 'Invitation validity renewed.' : 'Invitation revoked.'}</p>}
    {['unknown', 'blocked'].includes(p.email ?? '') && <p className="sr-alert warning" role="status">{p.email === 'unknown' ? 'The email result could not be confirmed. Check its status below and the provider logs before resending.' : 'No new email was sent. Review the invitation below and wait at least two minutes after the previous attempt before retrying.'}</p>}
    <div className="team-detail-grid"><div>
      <section className="sr-panel team-email-panel" aria-labelledby="invitation-email-heading"><div className="sr-panel-heading"><h2 id="invitation-email-heading">Invitation email</h2><span className={`sr-status ${delivery?.status === 'sent' ? 'completed' : delivery?.status === 'failed' ? 'cancelled' : 'new'}`}>{emailResult.error ? 'Status unavailable' : invitationEmailLabel(delivery)}</span></div>
        {delivery && <p className="sr-help">Last attempt {serviceTime(delivery.created_at, tz)}.</p>}
        {delivery?.status === 'sent' && <p className="sr-help">The email provider accepted this invitation. Inbox delivery is not confirmed here; ask the recipient to check their inbox and spam folder.</p>}
        {delivery && ['failed', 'unknown'].includes(delivery.status) && <p className="sr-alert warning" role="status">{invitationEmailError(delivery.error_code)} Your invitation and selected access are saved.</p>}
        {delivery?.status === 'sending' && <p className="sr-help">Refresh to check the result. If it stays unconfirmed, check the provider logs before sending another email.</p>}
        {!emailReady && valid && <p className="sr-alert info">Invitation email is not configured. Ask platform support to finish the email sender setup. You can copy and share the signup instructions below.</p>}
        {valid && d.can_manage && emailReady && <SendInvitationEmail key={`${i.version}:${delivery?.id ?? 'none'}`} tid={tid} id={i.id} version={i.version} request={randomUUID()} property={pid} email={i.email} resend={!!delivery} />}
        {valid && <CopyInvitation email={i.email} business={d.tenant_name} />}
        {i.state === 'expired' && <p className="sr-alert warning">This invitation has expired. Renew it before asking the person to join.</p>}
        {i.status === 'revoked' && <p>This invitation cannot be accepted or emailed again.</p>}
        {i.status === 'accepted' && <p>This teammate has already joined. Manage their access from the staff directory.</p>}
      </section>
      <section className="sr-panel"><h2>Invitation details</h2><dl className="sr-facts"><div><dt>Invited address</dt><dd>{i.email}</dd></div><div><dt>Valid until</dt><dd>{serviceTime(i.expires_at, tz)}</dd></div><div><dt>Created</dt><dd>{serviceTime(i.created_at, tz)}</dd></div><div><dt>Accepted</dt><dd>{i.accepted_at ? serviceTime(i.accepted_at, tz) : 'Not accepted'}</dd></div></dl>
        {i.status === 'pending' && <p className="sr-help">The person signs in or creates an account with this exact email, confirms it if requested, then opens Today to join. Existing business membership is never promoted by invitation.</p>}
        {i.status === 'accepted' && i.accepted_by && d.member_exists && <Link href={`/t/${tid}/team/members/${i.accepted_by}?property=${pid}`}>Review current staff access →</Link>}
        {i.status === 'accepted' && !d.member_exists && <p className="sr-help">This person no longer belongs to the business. Their accepted invitation remains in the history.</p>}
      </section>
      <section className="sr-panel"><h2>Access offered</h2>{i.tenant_role === 'admin' ? <PermissionPreview selected={[]} roles={d.roles} full /> : <div className="team-invited-hotels">{d.properties.filter(pr => i.grants.some(g => g.property_id === pr.id)).map(pr => { const selected = i.grants.filter(g => g.property_id === pr.id).map(g => g.role_key); return <div key={pr.id}><h3>{pr.name}</h3><p>{selected.map(k => d.roles.find(r => r.key === k)?.name ?? k).join(', ')}</p><PermissionPreview selected={selected} roles={d.roles} /></div>; })}{!i.grants.length && <p className="sr-help">No hotel roles were included. Assign hotel access after acceptance.</p>}<p className="sr-help">Permissions reflect current role definitions. Review the staff page for an accepted teammate’s current access.</p></div>}</section>
      <details className="sr-panel"><summary>Invitation history</summary><p className="sr-help">Latest 30 tracked changes.</p><TeamHistory events={d.events} timezone={tz} /></details>
    </div><aside><section className="sr-panel"><h2>Manage invitation</h2><InvitationControls key={i.version} tid={tid} detail={d} request={randomUUID()} property={pid} /></section><p className="sr-side-note">Renewing extends validity and attempts to email the updated invitation. Revoking prevents future acceptance and preserves this record. Previously sent emails do not grant access once an invitation is revoked.</p></aside></div>
  </div></TeamFrame>;
}

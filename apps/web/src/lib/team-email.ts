import 'server-only';

export type InvitationEmailContext = {
  email: string; business: string; business_role: string; expires_at: string;
  hotels: { name: string; roles: string[] }[];
};
export type TeamEmailConfig = { key: string; from: string; origin: string };
export type EmailResult = { status: 'sent' | 'failed' | 'unknown'; providerId?: string; error?: string };

// Direct reads let Next.js inline public build variables on Vercel. Reading the
// entire process.env object can miss build-only public variables in a function.
function emailEnvironment(): Record<string, string | undefined> {
  return { NODE_ENV: process.env.NODE_ENV, RESEND_API_KEY: process.env.RESEND_API_KEY,
    TEAM_EMAIL_FROM: process.env.TEAM_EMAIL_FROM, APP_URL: process.env.APP_URL,
    SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL };
}
export function teamEmailStatus(env: Record<string, string | undefined> = emailEnvironment()) {
  const issues: string[] = [];
  const key = env.RESEND_API_KEY?.trim(), from = env.TEAM_EMAIL_FROM?.trim() || 'Xcloak Hospitality <admin@xcloak.tech>';
  if (!key || !key.startsWith('re_')) issues.push('RESEND_API_KEY');
  if (/[\r\n]/.test(from) || !/^[^<>\s@]+@[^<>\s@]+\.[^<>\s@]+$/.test(from.match(/<([^<>]+)>$/)?.[1] ?? from)) issues.push('TEAM_EMAIL_FROM');
  try {
    const url = new URL(env.APP_URL ?? '');
    if (url.username || url.password || (url.protocol !== 'https:' && !(env.NODE_ENV !== 'production' && url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname)))) issues.push('APP_URL');
  } catch { issues.push('APP_URL'); }
  if (!env.SUPABASE_SERVICE_ROLE_KEY) issues.push('SUPABASE_SERVICE_ROLE_KEY');
  if (!env.NEXT_PUBLIC_SUPABASE_URL) issues.push('NEXT_PUBLIC_SUPABASE_URL');
  return { configured: issues.length === 0, issues };
}
export function teamEmailConfig(env: Record<string, string | undefined> = emailEnvironment()): TeamEmailConfig | null {
  if (!teamEmailStatus(env).configured) return null;
  return { key: env.RESEND_API_KEY!.trim(), from: env.TEAM_EMAIL_FROM?.trim() || 'Xcloak Hospitality <admin@xcloak.tech>', origin: new URL(env.APP_URL!).origin };
}

const escapeHtml = (value: string) => value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]!));
export function invitationEmail(context: InvitationEmailContext, config: Pick<TeamEmailConfig, 'from' | 'origin'>) {
  const login = new URL('/login', config.origin).toString(), signup = new URL('/signup', config.origin).toString();
  const business = context.business.replace(/[\r\n\x00-\x1f]/g, ' ').slice(0, 150);
  const access = context.business_role === 'admin'
    ? ['Business administrator: full access to all current and future hotels.']
    : context.hotels.length ? context.hotels.map(h => `${h.name}: ${h.roles.join(', ')}`) : ['Business membership only. Hotel roles will be assigned by your administrator.'];
  const expires = new Intl.DateTimeFormat('en', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' }).format(new Date(context.expires_at)) + ' UTC';
  const text = `You’re invited to join ${business} on Hospitality.\n\nUse this exact email address: ${context.email}\n\nYour access:\n${access.join('\n')}\n\nAlready have an account? Sign in: ${login}\nNew to Hospitality? Create an account: ${signup}\nConfirm your email if requested, then open Today (the dashboard). Your invitation is accepted automatically for this confirmed email.\n\nAccept before ${expires}. Expired or revoked invitations do not grant access.\nIf you weren’t expecting this invitation, you can ignore it. No password or payment is required by email.`;
  const html = `<div style="font-family:Arial,sans-serif;line-height:1.7;color:#203653;max-width:600px;margin:auto;padding:24px"><p style="font-size:18px;font-weight:bold">Hospitality</p><h1 style="font-size:25px">Join ${escapeHtml(business)}</h1><p>You’ve been invited to your hotel team. Use <strong>${escapeHtml(context.email)}</strong> to sign in or create your account.</p><h2 style="font-size:18px">Your access</h2><ul>${access.map(a => `<li>${escapeHtml(a)}</li>`).join('')}</ul><p><a href="${escapeHtml(login)}" style="display:inline-block;background:#203653;color:white;text-decoration:none;border-radius:6px;padding:10px 20px">Sign in to join your team</a></p><p>New to Hospitality? <a href="${escapeHtml(signup)}">Create your account</a>.</p><p>Confirm your email if requested, then open <strong>Today</strong>. Your invitation is accepted automatically for this confirmed email.</p><p>Accept before <strong>${escapeHtml(expires)}</strong>. Expired or revoked invitations do not grant access.</p><p style="font-size:13px;color:#667085">If you weren’t expecting this invitation, you can ignore it. No password or payment is required by email.</p></div>`;
  return { from: config.from, to: [context.email], subject: `You’re invited to ${business} · Hospitality`, text, html };
}

export async function sendInvitationEmail(context: InvitationEmailContext, deliveryId: string, config: TeamEmailConfig, fetcher: typeof fetch = fetch): Promise<EmailResult> {
  try {
    const response = await fetcher('https://api.resend.com/emails', {
      method: 'POST', cache: 'no-store', signal: AbortSignal.timeout(15000),
      headers: { Authorization: `Bearer ${config.key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `team-invitation/${deliveryId}` },
      body: JSON.stringify(invitationEmail(context, config)),
    });
    if (!response.ok) {
      if (response.status >= 500 || response.status === 409 || response.status === 408) return { status: 'unknown', error: 'uncertain' };
      return { status: 'failed', error: response.status === 429 ? 'rate_limit' : response.status === 401 ? 'authorization' : response.status === 403 ? 'sender' : 'provider' };
    }
    const data = await response.json();
    return typeof data.id === 'string' && /^[a-zA-Z0-9_-]{1,200}$/.test(data.id)
      ? { status: 'sent', providerId: data.id } : { status: 'unknown', error: 'uncertain' };
  } catch { return { status: 'unknown', error: 'uncertain' }; }
}

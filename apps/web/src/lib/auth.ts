export type AuthState = { error?: string; message?: string };
export function authEmailError(error: { code?: string; status?: number }, intent: 'signup' | 'confirmation' | 'recovery') {
  if (error.status === 429 || ['over_email_send_rate_limit', 'over_request_rate_limit'].includes(error.code ?? '')) return 'Too many email requests. Wait a few minutes before trying again.';
  if (['email_address_invalid', 'email_address_not_allowed'].includes(error.code ?? '')) return 'Check your email address and try again.';
  if (error.code === 'email_address_not_authorized' || error.status === 500 || error.status === 502 || error.status === 503) return 'We couldn’t send your email right now. Try again shortly. If it continues, contact support.';
  return intent === 'signup' ? 'We couldn’t create your account. Try again, or sign in if you already have an account.' : intent === 'confirmation' ? 'We couldn’t send another confirmation link. Wait a few minutes and try again.' : 'We couldn’t send the reset email right now. Wait a few minutes and try again.';
}
export const safeNext = (value: unknown): string => {
  if (typeof value !== 'string' || !value.startsWith('/') || value.startsWith('//') || /[\\\s\x00-\x1f]/.test(value)) return '/dashboard';
  const path = value.split(/[?#]/)[0];
  if (['/login', '/signup', '/forgot-password', '/reset-password', '/auth'].some(p => path === p || path.startsWith(`${p}/`))) return '/dashboard';
  return value;
};
export const validEmail = (s: string) => s.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
export const passwordChecks = (s: string) => [
  { label: 'At least 12 characters', valid: s.length >= 12 },
  { label: 'Uppercase and lowercase letters', valid: /[a-z]/.test(s) && /[A-Z]/.test(s) },
  { label: 'A number or symbol', valid: /[^a-zA-Z\s]/.test(s) },
];

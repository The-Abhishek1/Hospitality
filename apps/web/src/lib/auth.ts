export type AuthState = { error?: string; message?: string };
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

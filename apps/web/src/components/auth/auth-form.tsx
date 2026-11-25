"use client";
import Link from 'next/link';
import { useActionState, useState } from 'react';
import { signIn, signUp, requestReset, resetPassword, resendConfirmation } from '@/app/login/actions';
import { passwordChecks, type AuthState } from '@/lib/auth';
type Mode = 'login' | 'signup' | 'forgot' | 'reset';
const copy = {
  login: { eyebrow: 'WELCOME BACK', title: 'Your next great stay starts here.', description: 'Sign in to your hotel workspace.', button: 'Sign in to workspace', pending: 'Signing you in…' },
  signup: { eyebrow: 'A FRESH START', title: 'Make room for better operations.', description: 'Create your account. Set up your hotel or join your team next.', button: 'Create your account', pending: 'Creating your account…' },
  forgot: { eyebrow: 'LET’S GET YOU BACK', title: 'Forgot your password?', description: 'Enter your account email and we’ll send you a reset link.', button: 'Send reset link', pending: 'Sending your link…' },
  reset: { eyebrow: 'A LITTLE REFRESH', title: 'Set a new password.', description: 'Choose a strong password to keep your workspace secure.', button: 'Update password', pending: 'Updating password…' },
};
function Submit({ mode, pending }: { mode: Mode; pending: boolean }) {
  return <button type="submit" className="auth-submit" disabled={pending}>{pending ? <><span className="auth-spinner" />{copy[mode].pending}</> : <>{copy[mode].button}<span aria-hidden="true">↗</span></>}</button>;
}
export function AuthForm({ mode, next = '/dashboard', initial = {} }: { mode: Mode; next?: string; initial?: AuthState }) {
  const actions = { login: signIn, signup: signUp, forgot: requestReset, reset: resetPassword };
  const [state, action, pending] = useActionState(actions[mode], initial);
  const [resendState, resendAction, resending] = useActionState(resendConfirmation, {});
  const [password, setPassword] = useState(''), [confirm, setConfirm] = useState(''), [name, setName] = useState(''), [email, setEmail] = useState(''), [visible, setVisible] = useState(false);
  const c = copy[mode], creating = mode === 'signup' || mode === 'reset', success = !!state.message && mode !== 'login';
  const suffix = next === '/dashboard' ? '' : `?next=${encodeURIComponent(next)}`;
  return <>
    <span className="auth-form-eyebrow">{c.eyebrow}</span><h2 className="auth-title">{c.title}</h2><p className="auth-description">{c.description}</p>
    {(mode === 'login' || mode === 'signup') && <nav className="auth-tabs" aria-label="Account access"><Link href={`/login${suffix}`} aria-current={mode === 'login' ? 'page' : undefined}>Sign in</Link><Link href={`/signup${suffix}`} aria-current={mode === 'signup' ? 'page' : undefined}>Create account</Link></nav>}
    {state.error && <div className="auth-alert auth-alert-error" role="alert">{state.error}</div>}
    {state.message && <div className="auth-alert auth-alert-success" role="status"><strong>{mode === 'forgot' ? 'Check your inbox' : mode === 'signup' ? 'One more step' : 'You’re all set'}</strong>{state.message}</div>}
    {mode === 'signup' && success && <p className="auth-footnote">Confirmation requested for <strong>{email}</strong>. Check your spam folder too. Wrong address? <a href={`/signup${suffix}`}>Use another email</a>.</p>}
    {!success && <form action={action} className="auth-form">
      <input type="hidden" name="next" value={next} />
      {mode === 'signup' && <div className="auth-field"><label htmlFor="full_name">Full name</label><input id="full_name" name="full_name" autoComplete="name" placeholder="e.g. Alex Morgan" minLength={2} maxLength={100} required value={name} onChange={e => setName(e.target.value)} /></div>}
      {mode !== 'reset' && <div className="auth-field"><label htmlFor="email">Email address</label><input id="email" name="email" type="email" autoComplete="email" autoCapitalize="none" spellCheck={false} placeholder="you@yourhotel.com" maxLength={254} required value={email} onChange={e => setEmail(e.target.value)} /></div>}
      {mode !== 'forgot' && <div className="auth-field"><div className="auth-label-row"><label htmlFor="password">{mode === 'reset' ? 'New password' : 'Password'}</label>{mode === 'login' && <Link href="/forgot-password">Forgot password?</Link>}</div><div className="auth-password"><input id="password" name="password" type={visible ? 'text' : 'password'} autoComplete={creating ? 'new-password' : 'current-password'} placeholder={creating ? 'Create a strong password' : 'Enter your password'} required minLength={creating ? 12 : undefined} maxLength={128} value={password} onChange={e => setPassword(e.target.value)} aria-describedby={creating ? 'password-requirements' : undefined} /><button type="button" onClick={() => setVisible(!visible)} aria-label={visible ? 'Hide password' : 'Show password'} aria-pressed={visible}>{visible ? 'Hide' : 'Show'}</button></div>{creating && <ul className="auth-requirements" id="password-requirements">{passwordChecks(password).map(check => <li key={check.label} data-valid={check.valid}><span aria-hidden="true">{check.valid ? '✓' : '○'}</span>{check.label}{check.valid && <span className="sr-only"> — met</span>}</li>)}</ul>}</div>}
      {creating && <div className="auth-field"><label htmlFor="confirm_password">Confirm {mode === 'reset' ? 'new ' : ''}password</label><input id="confirm_password" name="confirm_password" type={visible ? 'text' : 'password'} autoComplete="new-password" placeholder="Enter your password again" required minLength={12} maxLength={128} value={confirm} onChange={e => setConfirm(e.target.value)} /></div>}
      <Submit mode={mode} pending={pending} />
    </form>}
    {mode === 'login' && <p className="auth-footnote">Invited by your hotel? Sign in or create an account with the email on your invitation.</p>}
    {mode === 'signup' && !success && <p className="auth-footnote">Joining an existing hotel? Use the email your hotel invited. Your team access is applied after you verify your email.</p>}
    {((mode === 'signup' && success) || (mode === 'login' && state.error)) && <form action={resendAction} className="auth-resend">
      <input type="hidden" name="email" value={email} /><input type="hidden" name="next" value={next} />
      <button type="submit" disabled={resending || !email}>{resending ? 'Sending confirmation…' : 'Resend confirmation email'}</button>
      {resendState.error && <p role="alert">{resendState.error}</p>}
      {resendState.message && <p role="status">{resendState.message}</p>}
    </form>}
    {(mode === 'forgot' || mode === 'reset' || success) && <Link className="auth-back" href={`/login${suffix}`}>← Back to sign in</Link>}
    {mode === 'reset' && state.error && <Link className="auth-back" href="/forgot-password">Request a new reset link</Link>}
    <div className="auth-security-note"><svg width="14" height="16" viewBox="0 0 14 16" fill="none" aria-hidden="true"><path d="M7 1 1.5 3v4c0 3.5 5.5 7 5.5 7s5.5-3.5 5.5-7V3L7 1Z" stroke="currentColor" strokeWidth="1.3"/><path d="m4.5 7 1.7 1.7L9.5 5.5" stroke="currentColor" strokeWidth="1.3"/></svg>Access is scoped to your hotel and role.</div>
  </>;
}

"use server";
import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { safeNext, validEmail, passwordChecks, authEmailError, type AuthState } from '@/lib/auth';
import {signupAccount,duplicateSignup,duplicateSignupMessage}from'@/lib/signup-account';
const value = (fd: FormData, key: string) => String(fd.get(key) ?? '');
function emailFailure(intent: 'signup' | 'confirmation' | 'recovery', error: { code?: string; status?: number }): AuthState {
  // Do not log addresses, passwords, token-bearing links or provider error bodies.
  console.error('auth_email_request_failed', { intent, code: error.code ?? 'unknown', status: error.status });
  return { error: authEmailError(error, intent) };
}
async function callbackUrl(next: string) {
  const origin = process.env.APP_URL ?? (await headers()).get('origin');
  if (!origin) throw new Error('Set APP_URL to the public web app URL.');
  const url = new URL('/auth/confirm', origin);
  url.searchParams.set('next', next);
  return url.toString();
}
export async function signIn(_: AuthState, fd: FormData): Promise<AuthState> {
  const email = value(fd, 'email').trim().toLowerCase(), password = value(fd, 'password');
  if (!validEmail(email) || !password || password.length > 128) return { error: 'Enter a valid email and your password.' };
  const db = await createClient();
  const { error } = await db.auth.signInWithPassword({ email, password });
  if (error) return { error: error.code === 'email_not_confirmed' ? 'Confirm your email before signing in. Check your inbox for your confirmation link.' : error.status === 429 ? 'Too many attempts. Wait a few minutes and try again.' : 'We couldn’t sign you in. Check your email and password and try again.' };
  redirect(safeNext(fd.get('next')));
}
export async function signUp(_: AuthState, fd: FormData): Promise<AuthState> {
  const name = value(fd, 'full_name').trim(), email = value(fd, 'email').trim().toLowerCase(), password = value(fd, 'password');
  if (name.length < 2 || name.length > 100) return { error: 'Enter your full name (2–100 characters).' };
  if (!validEmail(email)) return { error: 'Enter a valid email address.' };
  if (password.length > 128 || passwordChecks(password).some(c => !c.valid)) return { error: 'Use a password that meets all three requirements below.' };
  if (password !== value(fd, 'confirm_password')) return { error: 'Your passwords don’t match.' };
  const address=(await headers()).get('x-forwarded-for')?.split(',')[0]?.trim()||'local';
  const account=await signupAccount(email,address);
  if(account==='exists'||account==='pending')return{error:duplicateSignupMessage};
  if(account==='limited')return{error:'Too many signup attempts. Wait a few minutes before trying again.'};
  if(account==='unavailable')return{error:'Account creation is temporarily unavailable. Please try again shortly.'};
  const next = safeNext(fd.get('next')), db = await createClient();
  const { data, error } = await db.auth.signUp({ email, password, options: { data: { full_name: name }, emailRedirectTo: await callbackUrl(next) } });
  if(duplicateSignup(data.user,error))return{error:duplicateSignupMessage};
  if (error) return emailFailure('signup', error);
  if (!data.session) return { message: 'Check your inbox for your account confirmation link. Check your spam folder too.' };
  if (next === '/dashboard') {
    // Resolve first-time setup before the client follows the action redirect.
    // An invited teammate should enter their assigned workspace instead.
    await db.rpc('accept_staff_invitations');
    const {data: memberships, error: membershipError} = await db.from('tenant_memberships').select('tenant_id').eq('user_id', data.user!.id).limit(1);
    if (!membershipError && !memberships?.length) redirect('/onboarding');
  }
  redirect(next);
}
export async function requestReset(_: AuthState, fd: FormData): Promise<AuthState> {
  const email = value(fd, 'email').trim().toLowerCase();
  if (!validEmail(email)) return { error: 'Enter a valid email address.' };
  const db = await createClient();
  const { error } = await db.auth.resetPasswordForEmail(email, { redirectTo: await callbackUrl('/reset-password') });
  if (error) return emailFailure('recovery', error);
  return { message: 'If an account exists for this email, you’ll receive a password reset link. Check your inbox and spam folder.' };
}
export async function resendConfirmation(_: AuthState, fd: FormData): Promise<AuthState> {
  const email = value(fd, 'email').trim().toLowerCase();
  if (!validEmail(email)) return { error: 'Enter your email address before requesting a confirmation link.' };
  const db = await createClient();
  const { error } = await db.auth.resend({ type: 'signup', email, options: { emailRedirectTo: await callbackUrl(safeNext(fd.get('next'))) } });
  if (error) return emailFailure('confirmation', error);
  return { message: 'If your account needs confirmation, a new link is on its way. Check your inbox and spam folder.' };
}
export async function resetPassword(_: AuthState, fd: FormData): Promise<AuthState> {
  const password = value(fd, 'password');
  if (password.length > 128 || passwordChecks(password).some(c => !c.valid)) return { error: 'Use a password that meets all three requirements below.' };
  if (password !== value(fd, 'confirm_password')) return { error: 'Your passwords don’t match.' };
  const db = await createClient();
  const { data: { user } } = await db.auth.getUser();
  if (!user) return { error: 'Your reset session expired. Request a new password reset link.' };
  const { error } = await db.auth.updateUser({ password });
  if (error) return { error: error.code === 'same_password' ? 'Choose a password different from your current one.' : 'We couldn’t update your password. Request a fresh reset link and try again.' };
  await db.auth.signOut();
  redirect('/login?message=Password+updated.+Sign+in+with+your+new+password.');
}

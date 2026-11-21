"use server";
import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { safeNext, validEmail, passwordChecks, type AuthState } from '@/lib/auth';
const value = (fd: FormData, key: string) => String(fd.get(key) ?? '');
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
  const next = safeNext(fd.get('next')), db = await createClient();
  const { data, error } = await db.auth.signUp({ email, password, options: { data: { full_name: name }, emailRedirectTo: await callbackUrl(next) } });
  if (error) return { error: error.status === 429 ? 'Please wait a few minutes before requesting another email.' : 'We couldn’t create your account. Try again, or sign in if you already have an account.' };
  if (!data.session) return { message: 'Check your inbox for a confirmation link. If you already have an account, sign in or reset your password.' };
  redirect(next);
}
export async function requestReset(_: AuthState, fd: FormData): Promise<AuthState> {
  const email = value(fd, 'email').trim().toLowerCase();
  if (!validEmail(email)) return { error: 'Enter a valid email address.' };
  const db = await createClient();
  const { error } = await db.auth.resetPasswordForEmail(email, { redirectTo: await callbackUrl('/reset-password') });
  if (error) return { error: 'We couldn’t send the reset email right now. Wait a few minutes and try again.' };
  return { message: 'If an account exists for this email, you’ll receive a password reset link. Check your inbox and spam folder.' };
}
export async function resendConfirmation(_: AuthState, fd: FormData): Promise<AuthState> {
  const email = value(fd, 'email').trim().toLowerCase();
  if (!validEmail(email)) return { error: 'Enter your email address before requesting a confirmation link.' };
  const db = await createClient();
  const { error } = await db.auth.resend({ type: 'signup', email, options: { emailRedirectTo: await callbackUrl(safeNext(fd.get('next'))) } });
  if (error) return { error: 'We couldn’t send another link right now. Wait a few minutes and try again.' };
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

import { type NextRequest, NextResponse } from 'next/server';
import { type EmailOtpType } from '@supabase/supabase-js';
import { createClient } from '@/lib/supabase/server';
import { safeNext } from '@/lib/auth';
export async function GET(request: NextRequest) {
  const p = request.nextUrl.searchParams, code = p.get('code'), hash = p.get('token_hash'), type = p.get('type');
  const db = await createClient();
  let error: unknown = true;
  if (code) ({ error } = await db.auth.exchangeCodeForSession(code));
  else if (hash && type && ['signup', 'recovery', 'invite', 'email'].includes(type)) ({ error } = await db.auth.verifyOtp({ token_hash: hash, type: type as EmailOtpType }));
  const next = type === 'recovery' || p.get('next') === '/reset-password' ? '/reset-password' : safeNext(p.get('next'));
  return NextResponse.redirect(new URL(error ? '/login?error=This+email+link+has+expired+or+is+invalid.+Try+signing+in+or+request+a+new+password+reset+link.' : next, request.url));
}

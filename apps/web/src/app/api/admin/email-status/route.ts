import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { teamEmailStatus } from '@/lib/team-email';

export async function GET() {
  const db = await createClient(), { data: { user } } = await db.auth.getUser();
  const options = { headers: { 'Cache-Control': 'no-store' } };
  if (!user) return NextResponse.json({ error: 'Sign in required.' }, { ...options, status: 401 });
  const { data, error } = await db.from('platform_admins').select('user_id').eq('user_id', user.id).maybeSingle();
  if (error || !data) return NextResponse.json({ error: 'Platform administrator access required.' }, { ...options, status: 403 });
  // Variable names only: never return credentials, sender values or provider data.
  return NextResponse.json(teamEmailStatus(), options);
}

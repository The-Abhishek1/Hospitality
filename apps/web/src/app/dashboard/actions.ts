"use server";
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
export async function signOut() {
  const db = await createClient();
  const { error } = await db.auth.signOut();
  if (error) redirect('/dashboard?error=Could+not+sign+out.+Please+try+again.');
  redirect('/login');
}

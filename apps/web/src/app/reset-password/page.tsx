import { redirect } from 'next/navigation';
import { AuthShell } from '@/components/auth/auth-shell';
import { AuthForm } from '@/components/auth/auth-form';
import { createClient } from '@/lib/supabase/server';
export const metadata = { title: 'Choose a new password · Hospitality' };
export default async function ResetPasswordPage() {
  const db = await createClient();
  const { data: { user } } = await db.auth.getUser();
  if (!user) redirect('/login?error=Open+the+password+reset+link+from+your+email,+or+request+a+new+one.');
  return <AuthShell><AuthForm mode="reset" /></AuthShell>;
}

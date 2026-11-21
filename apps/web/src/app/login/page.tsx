import { AuthShell } from '@/components/auth/auth-shell';
import { AuthForm } from '@/components/auth/auth-form';
import { safeNext } from '@/lib/auth';
export const metadata = { title: 'Sign in · Hospitality' };
export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; error?: string; message?: string }> }) {
  const p = await searchParams;
  return <AuthShell><AuthForm mode="login" next={safeNext(p.next)} initial={{ error: p.error, message: p.message }} /></AuthShell>;
}

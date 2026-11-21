import { AuthShell } from '@/components/auth/auth-shell';
import { AuthForm } from '@/components/auth/auth-form';
import { safeNext } from '@/lib/auth';
export const metadata = { title: 'Create account · Hospitality' };
export default async function SignupPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  const { next } = await searchParams;
  return <AuthShell><AuthForm mode="signup" next={safeNext(next)} /></AuthShell>;
}

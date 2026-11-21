import { AuthShell } from '@/components/auth/auth-shell';
import { AuthForm } from '@/components/auth/auth-form';
export const metadata = { title: 'Reset your password · Hospitality' };
export default function ForgotPasswordPage() { return <AuthShell><AuthForm mode="forgot" /></AuthShell>; }

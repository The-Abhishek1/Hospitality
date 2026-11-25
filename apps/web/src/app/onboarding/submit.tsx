"use client";

import { useFormStatus } from 'react-dom';

export function CreateHotelSubmit() {
  const { pending } = useFormStatus();
  return <div className="onboarding-submit" aria-busy={pending}>
    <button type="submit" disabled={pending}>
      {pending && <span className="onboarding-spinner" aria-hidden="true" />}
      {pending ? 'Creating hotel…' : 'Create hotel & continue →'}
    </button>
    <p className="onboarding-progress" role="status" aria-live="polite" aria-atomic="true">
      {pending ? 'Setting up your workspace. Hotel settings will open automatically.' : ''}
    </p>
  </div>;
}

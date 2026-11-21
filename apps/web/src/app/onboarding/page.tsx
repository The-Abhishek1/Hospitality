import { createWorkspace } from "./actions";

const input = "w-full rounded-md border border-slate-300 px-3 py-2";

export default async function OnboardingPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;
  return (
    <main className="mx-auto max-w-md p-8">
      <h1 className="mb-1 text-2xl font-semibold">Set up your workspace</h1>
      <p className="mb-6 text-sm text-slate-600">One business, one or more properties. You can add more later.</p>
      {error && <p className="mb-4 rounded bg-red-50 p-2 text-sm text-red-700">{error}</p>}
      <form action={createWorkspace} className="space-y-3">
        <input name="business" placeholder="Business name" required className={input} />
        <input name="property" placeholder="First property name" required className={input} />
        <select name="type" className={input} defaultValue="hotel">
          <option value="hotel">Hotel</option>
          <option value="resort">Resort</option>
          <option value="hostel">Hostel</option>
          <option value="homestay">Homestay</option>
        </select>
        <input name="timezone" defaultValue="Asia/Kolkata" className={input} />
        <button className="w-full rounded-md bg-slate-900 px-3 py-2 font-medium text-white">Create workspace</button>
      </form>
    </main>
  );
}

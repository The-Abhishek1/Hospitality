import Link from 'next/link';
import {notFound} from 'next/navigation';
import {createClient} from '@/lib/supabase/server';
import {validId} from '@/lib/reservations';
import {deletionGroups} from '@/lib/hotel-deletion';
import type {BusinessDeletionPreview} from '@/lib/business-deletion';
import {DeleteBusiness} from '@/components/platform/delete-hotel';
export const metadata = {title: 'Delete business · Platform administration'};
export default async function DeleteBusinessPage({params}: {params: Promise<{tenantId: string}>}) {
  const {tenantId} = await params;
  if (!validId(tenantId)) notFound();
  const db = await createClient();
  const {data, error} = await db.rpc('platform_business_deletion_preview', {p_tenant: tenantId});
  if (error?.code === 'P0002') notFound();
  if (error || !data) return <section className="pa-panel"><h1>Couldn’t load business deletion details</h1><p>Refresh to verify platform access and review the business.</p></section>;
  const preview = data as BusinessDeletionPreview;
  return <><Link className="pa-back" href={preview.state === 'complete' ? '/admin?view=businesses' : `/admin/businesses/${tenantId}`}>← {preview.state === 'complete' ? 'Business accounts' : 'Business account'}</Link><div className="pa-heading"><div><span className="pa-eyebrow">PERMANENT BUSINESS REMOVAL</span><h1>{preview.name}</h1><p>This removes the business and every hotel it owns. This cannot be undone.</p></div></div>
    {preview.state !== 'complete' && <section className="pa-panel"><h2>{preview.state === 'review' ? 'Data to remove' : 'Deletion scope'}</h2><dl className="pa-details"><div><dt>Hotels</dt><dd>{preview.hotel_remaining} remaining / {preview.hotel_total} total</dd></div>{deletionGroups(preview.counts).map(([label, count]) => <div key={label}><dt>{label}</dt><dd>{count}</dd></div>)}<div><dt>Business guest profiles</dt><dd>{preview.guest_profiles}</dd></div><div><dt>Team memberships / invitations</dt><dd>{preview.members} / {preview.invitations}</dd></div><div><dt>Custom roles / subscription records</dt><dd>{preview.custom_roles} / {preview.subscription_records}</dd></div><div><dt>Uploaded files remaining</dt><dd>{preview.files_remaining}</dd></div></dl>
      {!!preview.hotels?.length && <details className="pa-business-hotel-list"><summary>Hotels included ({preview.hotel_total})</summary><ul>{preview.hotels.map(h => <li key={h.id}>{h.name}</li>)}</ul></details>}
      <p className="pa-help">{preview.job && 'Record counts show the original deletion scope. Remaining hotel and file counts are current. '}All hotel-owned data is included. Owner and staff login accounts and other businesses are preserved.</p></section>}
    <DeleteBusiness preview={preview}/>
  </>;
}

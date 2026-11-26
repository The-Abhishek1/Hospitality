import Link from 'next/link';
import {notFound} from 'next/navigation';
import {createClient} from '@/lib/supabase/server';
import {validId} from '@/lib/reservations';
import {deletionGroups, type HotelDeletionPreview} from '@/lib/hotel-deletion';
import {DeleteHotel} from '@/components/platform/delete-hotel';
export const metadata = {title: 'Delete hotel · Platform administration'};
export default async function DeleteHotelPage({params}: {params: Promise<{propertyId: string}>}) {
  const {propertyId} = await params;
  if (!validId(propertyId)) notFound();
  const db = await createClient();
  const {data, error} = await db.rpc('platform_hotel_deletion_preview', {p_property: propertyId});
  if (error?.code === 'P0002') notFound();
  if (error || !data) return <section className="pa-panel"><h1>Couldn’t load deletion details</h1><p>Refresh this page to verify platform access and review the hotel.</p></section>;
  const preview = data as HotelDeletionPreview;
  return <><Link className="pa-back" href={`/admin/businesses/${preview.tenant}`}>← Business account</Link><div className="pa-heading"><div><span className="pa-eyebrow">PERMANENT HOTEL REMOVAL</span><h1>{preview.name}</h1><p>Review this hotel’s data before deleting it. This cannot be undone.</p></div></div>
    {preview.state !== 'complete' && <section className="pa-panel"><h2>Data to remove</h2><dl className="pa-details">{deletionGroups(preview.counts).map(([label, count]) => <div key={label}><dt>{label}</dt><dd>{count}</dd></div>)}<div><dt>Uploaded files remaining</dt><dd>{preview.files_remaining}</dd></div></dl><p className="pa-help">All hotel-owned records are included, including configuration, channel connections and internal processing records.</p></section>}
    <DeleteHotel preview={preview}/>
  </>;
}

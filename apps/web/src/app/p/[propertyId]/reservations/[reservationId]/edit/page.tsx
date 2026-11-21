import Link from 'next/link';
import { notFound } from 'next/navigation';
import { randomUUID } from 'node:crypto';
import { createClient } from '@/lib/supabase/server';
import { todayIn } from '@/lib/dates';
import { validId,type Detail,type RoomType,type RatePlan } from '@/lib/reservations';
import { BookingForm } from '@/components/reservations/booking-form';
import '@/components/reservations/reservations.css';
export const metadata={title:'Edit reservation · Hospitality'};
export default async function EditReservation({params}:{params:Promise<{propertyId:string;reservationId:string}>}){
 const {propertyId:pid,reservationId:id}=await params;if(!validId(pid)||!validId(id))notFound();
 const db=await createClient();
 const [dr,pr,tr,rr]=await Promise.all([db.rpc('reservation_detail',{p_property:pid,p_id:id}),db.from('properties').select('timezone,currency').eq('id',pid).single(),db.from('accommodation_types').select('id,name,max_occupancy,base_rate').eq('property_id',pid).order('name'),db.from('rate_plans').select('id,name,adjustment_percent').eq('property_id',pid).order('name')]);
 if(dr.error?.code==='P0002')notFound();
 if(dr.error||pr.error||tr.error||rr.error)throw new Error('Could not load this stay. Please refresh.');
 const detail=dr.data as Detail;
 if(!detail.can_write||detail.stay.status!=='confirmed'||detail.stay.source==='ota')return <section className="res-empty"><h2>This stay cannot be edited here</h2><p>Only confirmed direct or walk-in reservations can be changed. Use the channel for channel bookings and room moves for in-house guests.</p><Link href={`/p/${pid}/reservations/${id}`}>Back to reservation</Link></section>;
 return <div className="res-workspace"><div className="res-subheading"><div><Link href={`/p/${pid}/reservations/${id}`}>← Back to reservation</Link><h2>Edit stay · {detail.guest.full_name}</h2><p>Availability is checked before changes are saved. A failed change keeps the original room and dates.</p></div></div><BookingForm pid={pid} today={todayIn(pr.data.timezone)} currency={pr.data.currency} types={tr.data as RoomType[]} rates={rr.data as RatePlan[]} request={randomUUID()} existing={detail} initialIn={detail.stay.check_in}/></div>;
}

import Link from 'next/link';
import { randomUUID } from 'node:crypto';
import { createClient } from '@/lib/supabase/server';
import { todayIn } from '@/lib/dates';
import { validDay,validId,type RoomType,type RatePlan } from '@/lib/reservations';
import { BookingForm } from '@/components/reservations/booking-form';
import '@/components/reservations/reservations.css';
export const metadata={title:'New reservation · Hospitality'};
export default async function NewReservation({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{in?:string;type?:string;room?:string}>}){
 const {propertyId:pid}=await params,input=await searchParams,db=await createClient();
 const [pr,tr,rr,permissions,defaults]=await Promise.all([db.from('properties').select('timezone,currency').eq('id',pid).single(),db.from('accommodation_types').select('id,name,max_occupancy,base_rate').eq('property_id',pid).order('name'),db.from('rate_plans').select('id,name,adjustment_percent').eq('property_id',pid).order('name'),db.rpc('workspace_permissions',{p_property:pid}),db.rpc('property_booking_defaults',{p_property:pid})]);
 if(!permissions.data?.book)return <section className="res-empty"><h2>Booking permission required</h2><p>Ask your administrator for reservation write access.</p></section>;
 if(pr.error||tr.error||rr.error||defaults.error)throw new Error('Could not load booking setup. Please refresh.');
 const today=todayIn(pr.data.timezone),initialIn=validDay(input.in)&&input.in>=today?input.in:today;
 return <div className="res-workspace"><div className="res-subheading"><div><Link href={`/p/${pid}/reservations`}>← All reservations</Link><h2>New reservation</h2><p>Check the stay, add guest details, and confirm a room.</p></div><span className="res-status confirmed">Direct & walk-in</span></div><BookingForm pid={pid} today={today} currency={pr.data.currency} types={tr.data as RoomType[]} rates={rr.data as RatePlan[]} request={randomUUID()} initialIn={initialIn} defaults={defaults.data??undefined} initialType={tr.data.some(t=>t.id===input.type)?input.type:undefined} initialUnit={validId(input.room)?input.room:undefined}/></div>;
}

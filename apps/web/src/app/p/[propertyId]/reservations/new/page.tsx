import Link from 'next/link';
import { randomUUID } from 'node:crypto';
import { createClient } from '@/lib/supabase/server';
import { todayIn } from '@/lib/dates';
import { dayLabel,validDay,validId,type RoomType,type RatePlan } from '@/lib/reservations';
import { BookingForm } from '@/components/reservations/booking-form';
import '@/components/reservations/reservations.css';
export const metadata={title:'New reservation · Hospitality'};
export default async function NewReservation({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{in?:string;type?:string;room?:string;guest?:string;walkin?:string}>}){
 const {propertyId:pid}=await params,input=await searchParams,db=await createClient();
 const [pr,tr,rr,permissions,defaults]=await Promise.all([db.from('properties').select('timezone,currency').eq('id',pid).single(),db.from('accommodation_types').select('id,name,max_occupancy,base_rate').eq('property_id',pid).order('name'),db.from('rate_plans').select('id,name,adjustment_percent').eq('property_id',pid).order('name'),db.rpc('workspace_permissions',{p_property:pid}),db.rpc('property_booking_defaults',{p_property:pid})]);
 if(!permissions.data?.book)return <section className="res-empty"><h1>New reservation</h1><h2>Booking permission required</h2><p>Ask your administrator for reservation write access.</p></section>;
 if(pr.error||tr.error||rr.error||defaults.error)throw new Error('Could not load booking setup. Please refresh.');
 const{data:guests,error:guestError}=await db.rpc('frontdesk_guest_choices',{p_property:pid});if(guestError)throw new Error('Could not load returning guests. Please refresh.');
 let choices=guests??[];
 if(validId(input.guest)&&!choices.some((g:{id:string})=>g.id===input.guest)){
  const {data:stay}=await db.from('reservations').select('guest_id').eq('property_id',pid).eq('guest_id',input.guest).limit(1).maybeSingle();
  if(stay){const {data:guest}=await db.from('guests').select('id,full_name,phone,email').eq('id',input.guest).maybeSingle();if(guest)choices=[guest,...choices];}
 }
 const initialGuest=choices.some((g:{id:string})=>g.id===input.guest)?input.guest:undefined;
 const{data:welcome}=await db.rpc('booking_welcome_status',{p_property:pid});
 const today=todayIn(pr.data.timezone),initialIn=input.walkin==='1'?today:validDay(input.in)&&input.in>=today?input.in:today;
 return <div className="booking-page"><header className="booking-page-heading"><div><Link href={`/p/${pid}/reservations`}>← Reservations</Link><h1>{input.walkin==='1'&&permissions.data?.frontdesk?'Walk-in check-in':'New reservation'}</h1><p>{dayLabel(today)} · {pr.data.timezone}. Check availability, then confirm the guest.</p></div>{permissions.data?.channels&&<Link className="dash-button dash-secondary" href={`/p/${pid}/reservations/guests`}>Manage guests →</Link>}</header>{input.guest&&!initialGuest&&<p className="res-alert warning" role="status">This guest could not be selected. Choose a returning profile from this hotel.</p>}<BookingForm canWalkIn={Boolean(permissions.data?.frontdesk)} initialWalkIn={input.walkin==='1'} canManageGuests={Boolean(permissions.data?.channels)} welcome={welcome} guests={choices} initialGuest={initialGuest} pid={pid} today={today} currency={pr.data.currency} types={tr.data as RoomType[]} rates={rr.data as RatePlan[]} request={randomUUID()} initialIn={initialIn} defaults={defaults.data??undefined} initialType={tr.data.some(t=>t.id===input.type)?input.type:undefined} initialUnit={validId(input.room)?input.room:undefined}/></div>;
}

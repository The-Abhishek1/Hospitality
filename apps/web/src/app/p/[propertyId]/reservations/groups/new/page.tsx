import Link from'next/link';import{randomUUID}from'node:crypto';
import{createClient}from'@/lib/supabase/server';import{todayIn}from'@/lib/dates';
import{GroupBookingForm}from'@/components/reservations/group-booking-form';
import{type RoomType,type RatePlan}from'@/lib/reservations';
export const metadata={title:'Group booking · Hospitality'};
export default async function GroupNew({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{walkin?:string}>}){
 const{propertyId:pid}=await params,input=await searchParams,db=await createClient();
 const[permissions,property,types,rates,guests]=await Promise.all([db.rpc('workspace_permissions',{p_property:pid}),db.from('properties').select('timezone,currency').eq('id',pid).single(),db.from('accommodation_types').select('id,name,max_occupancy,base_rate').eq('property_id',pid).order('name'),db.from('rate_plans').select('id,name,adjustment_percent').eq('property_id',pid).order('name'),db.rpc('frontdesk_guest_choices',{p_property:pid})]);
 if(!permissions.data?.book)return <section><h1>Group booking</h1><p>Reservation write access is required.</p><Link href={`/p/${pid}/reservations`}>Back to reservations</Link></section>;
 if(property.error||types.error||rates.error||guests.error)throw Error('Could not load group booking setup. Refresh and try again.');
 return <div className="group-booking-page"><header className="group-page-heading"><div><Link href={`/p/${pid}/reservations`}>← Reservations</Link><h1>{input.walkin==='1'&&permissions.data.frontdesk?'Group walk-in':'New group booking'}</h1><p>Book multiple rooms in one flow. {property.data.timezone} · hotel time.</p></div><Link href={`/p/${pid}/reservations/groups`}>View group bookings →</Link></header><GroupBookingForm pid={pid} today={todayIn(property.data.timezone)} currency={property.data.currency} types={types.data as RoomType[]} rates={rates.data as RatePlan[]} guests={guests.data??[]} request={randomUUID()} canWalkIn={Boolean(permissions.data.frontdesk)} initialWalkIn={input.walkin==='1'}/></div>;
}

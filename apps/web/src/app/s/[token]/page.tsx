import{LegacyTaskLink}from'@/components/guest-tasks/task-tools';import{validToken}from'@/lib/guest-portal';import{GuestTaskUnavailable}from'@/components/guest-tasks/task-page';
export const dynamic='force-dynamic';export const metadata={robots:{index:false,follow:false},referrer:'no-referrer' as const};
export default async function LegacyGuestPage({params}:{params:Promise<{token:string}>}){const{token}=await params;return validToken(token)?<LegacyTaskLink token={token}/>:<GuestTaskUnavailable/>;}

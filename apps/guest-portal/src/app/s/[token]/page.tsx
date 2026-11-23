import LegacyTaskRedirect from'@/components/legacy-task-redirect';import{validToken}from'@/lib/portal';
export const dynamic='force-dynamic';export const metadata={title:'Opening your hotel task',referrer:'no-referrer' as const};
export default async function Page({params}:{params:Promise<{token:string}>}){const{token}=await params;return validToken(token)?<LegacyTaskRedirect token={token}/>:<main className="portal-landing"><h1>This link is unavailable.</h1><p>Return to your hotel’s WhatsApp chat for a fresh task link.</p></main>;}

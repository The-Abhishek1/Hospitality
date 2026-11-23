import LegacyTaskRedirect from'@/components/legacy-task-redirect';import{validToken}from'@/lib/portal';
export const dynamic='force-dynamic';
export default async function Page({params}:{params:Promise<{token:string;task:string}>}){const{token,task}=await params;return validToken(token)?<LegacyTaskRedirect token={token} task={task}/>:<main className="portal-landing"><h1>This link is unavailable.</h1><p>Ask your hotel for a fresh link.</p></main>;}

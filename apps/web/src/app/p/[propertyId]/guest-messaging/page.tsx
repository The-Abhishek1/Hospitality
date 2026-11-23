import {redirect} from 'next/navigation';
export default async function LegacyMessaging({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{tab?:string}>}){const{propertyId}=await params,q=await searchParams;redirect(`/p/${propertyId}/automations?tab=${q.tab==='setup'?'menu':q.tab==='journeys'?'rules':'templates'}`);}

import {redirect} from 'next/navigation';
export default async function LegacyTemplate({params}:{params:Promise<{propertyId:string}>}){const{propertyId}=await params;redirect(`/p/${propertyId}/whatsapp?tab=templates`);}

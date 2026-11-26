import {redirect} from 'next/navigation';
export default async function LegacyAutomations({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<Record<string,string|string[]|undefined>>}){
 const {propertyId}=await params,q=await searchParams,query=new URLSearchParams();
 for(const [key,value]of Object.entries(q)){if(Array.isArray(value))value.forEach(v=>query.append(key,v));else if(value!==undefined)query.set(key,value);}
 redirect(`/p/${propertyId}/whatsapp${query.size?'?'+query:''}`);
}

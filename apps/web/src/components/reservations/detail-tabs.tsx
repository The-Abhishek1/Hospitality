'use client';
import Link from 'next/link';
import {useEffect,useRef}from'react';
import {useRouter}from'next/navigation';
export function ReservationDetailTabs({base,tab,finance}:{base:string;tab:string;finance:boolean}){
 const router=useRouter(),previous=useRef(tab);
 useEffect(()=>{const followHash=()=>{const target=({'#guest-details':'guest','#stay-documents':'documents','#stay-actions':'overview','#stay-billing':'billing'}as Record<string,string>)[location.hash];if(target&&target!==tab){const url=new URL(location.href);url.searchParams.set('tab',target);router.replace(url.pathname+url.search+url.hash,{scroll:false});}};followHash();window.addEventListener('hashchange',followHash);return()=>window.removeEventListener('hashchange',followHash);},[router,tab]);
 useEffect(()=>{if(previous.current!==tab){previous.current=tab;document.querySelector<HTMLElement>('#stay-section-heading')?.focus({preventScroll:true});document.querySelector('.stay-detail-tabs')?.scrollIntoView({block:'nearest'});}},[tab]);
 const tabs=[['overview','Overview'],['guest','Guest details'],['documents','Documents'],['whatsapp','WhatsApp'],...(finance?[['billing','Billing']]:[]),['history','History']];
 return <nav className="stay-detail-tabs" aria-label="Reservation sections">{tabs.map(([id,label])=><Link key={id} aria-current={tab===id?'page':undefined} href={id==='overview'?base:`${base}?tab=${id}`} scroll={false}>{label}</Link>)}</nav>;
}

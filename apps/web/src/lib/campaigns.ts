import {displayDay,displayDateTime} from '@/lib/date-format';
export type CampaignFilters={from:string;to:string;status:string;source:string;q:string};
export type CampaignGuest={guest_id:string;guest_name:string;phone:string|null;last_departure:string;stays:number;exclusion:string|null};
export type CampaignAudience={total:number;eligible:number;rows:CampaignGuest[]};
export const defaultCampaignFilters:CampaignFilters={from:'',to:'',status:'checked_out',source:'all',q:''};
export function campaignFilters(raw:unknown):CampaignFilters{
 const p=raw&&typeof raw==='object'?raw as Record<string,unknown>:{};
 return{from:String(p.from??'').slice(0,10),to:String(p.to??'').slice(0,10),status:['all','confirmed','checked_in','checked_out'].includes(String(p.status))?String(p.status):'checked_out',source:['all','direct','walk_in','ota'].includes(String(p.source))?String(p.source):'all',q:String(p.q??'').trim().slice(0,100)};
}
export function campaignPage(value:unknown){const n=Number(value);return Number.isInteger(n)&&n>0?Math.min(n,10000):1;}
export function campaignTime(value:string,timezone:string){return displayDateTime(value,timezone);}

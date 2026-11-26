import {displayDay,displayDateTime} from '@/lib/date-format';
export const requestPriorities=['low','normal','high','urgent'] as const;
export const requestStatus=(s:string)=>({new:'New',in_progress:'In progress',completed:'Completed',cancelled:'Cancelled'}[s]??s.replaceAll('_',' '));
export const priorityLabel=(p:string)=>p.charAt(0).toUpperCase()+p.slice(1);
export const sourceLabel=(s:string)=>({staff:'Staff',portal:'Guest portal',whatsapp:'WhatsApp',qr:'QR'}[s]??s);
export function serviceFilters(p:Record<string,string|undefined>){return{q:(p.q??'').trim().slice(0,100),view:['active','overdue','mine','desk','unassigned','completed','cancelled','all'].includes(p.view??'')?p.view!:'active',priority:requestPriorities.includes(p.priority as typeof requestPriorities[number])?p.priority!:'',source:['staff','portal','whatsapp','qr'].includes(p.source??'')?p.source!:'',sort:['priority','deadline','newest'].includes(p.sort??'')?p.sort!:'priority',page:p.page&&/^\d+$/.test(p.page)?Math.min(100000,Math.max(1,Number(p.page))):1};}
export const validTarget=(s:string)=>s.trim()===''||/^\d{1,5}$/.test(s.trim())&&Number(s)>=1&&Number(s)<=10080;
export const serviceTime=(value:string,tz:string)=>displayDateTime(value,tz);
function duration(minutes:number){const m=Math.max(1,Math.ceil(minutes));return m<60?`${m}m`:m<1440?`${Math.floor(m/60)}h${m%60?` ${m%60}m`:''}`:`${Math.floor(m/1440)}d${Math.floor(m%1440/60)?` ${Math.floor(m%1440/60)}h`:''}`;}
export function deadlineState(due:string|null,status:string,completed:string|null,now:string){
 if(status==='cancelled')return{label:'Cancelled',kind:'none'};
 if(!due||Number.isNaN(Date.parse(due)))return{label:'No response target',kind:'none'};
 if(status==='completed'){if(!completed)return{label:'Completed',kind:'none'};return Date.parse(completed)<=Date.parse(due)?{label:'Completed within target',kind:'met'}:{label:'Completed after target',kind:'late'};}
 const minutes=(Date.parse(due)-Date.parse(now))/60000;return minutes<0?{label:`Overdue by ${duration(-minutes)}`,kind:'overdue'}:{label:`Due in ${duration(minutes)}`,kind:'due'};
}
export type ServiceItem={id:string;version:number;name:string;description:string;active:boolean;default_priority:string;target_minutes:number|null;category_id:string;category:string;task_kind:string|null;assignee_id:string|null;assignee_name:string|null;department_id:string|null;department_name:string|null};
export type StayOption={id:string;guest_name:string;status:string;check_in:string;check_out:string;room:string|null};
export type RequestSetup={stay_total:number;stays:StayOption[];selected:StayOption|null;services:ServiceItem[]};
export type CatalogSetup={services:ServiceItem[];categories:{id:string;name:string}[];departments:{id:string;name:string}[];assignees:{id:string;name:string}[]};
export type RequestRow={id:string;version:number;title:string;notes:string|null;status:string;priority:string;source:string;created_at:string;updated_at:string;completed_at:string|null;due_at:string|null;overdue:boolean|null;guest_name:string;reservation_id:string;stay_status:string;room:string|null;requested_room:string|null;service_name:string|null;category:string|null;task_id:string|null;task_status:string|null;task_kind:string|null;assignee_id:string|null;assignee_name:string|null};
export type RequestWorkspace={total:number;page:number;rows:RequestRow[];stats:{active:number;overdue:number;unassigned:number;desk:number;completed_today:number};timezone:string;day:string;updated_at:string;user_id:string;full_read:boolean;can_manage:boolean;can_catalog:boolean};
export type RequestDetail={request:RequestRow;task:{id:string;status:string;kind:string;priority:string;due_at:string|null;assignee_id:string|null;department:string|null;started_at:string|null;completed_at:string|null}|null;can_manage:boolean;can_assign:boolean;can_work:boolean;can_comment:boolean;can_claim:boolean;can_reservations:boolean;feedback:{rating:number;comment:string|null;created_at:string;recorded_via:string}|null;assignees:{id:string;name:string}[];events:{id:string;event_type:string;details:Record<string,unknown>;created_at:string;actor_name:string|null;context:string}[];comments:{id:string;body:string;created_at:string;author_name:string|null;context:string}[]};

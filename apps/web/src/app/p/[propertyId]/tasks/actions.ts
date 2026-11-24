"use server";
import {redirect} from 'next/navigation';
import {revalidatePath} from 'next/cache';
import {createClient} from '@/lib/supabase/server';
import {validId} from '@/lib/reservations';
import {validTarget} from '@/lib/service-desk';
import {taskKinds,taskPriorities,parseChecklist} from '@/lib/tasks';
export type TaskState={error?:string;fields?:Record<string,string>};
const field=(f:FormData,k:string)=>String(f.get(k)??'').trim();
const snapshot=(f:FormData)=>Object.fromEntries(['title','description','kind','priority','assignee','unit','department','target_minutes','checklist','operation','status','reason','body','deadline','label'].map(k=>[k,field(f,k).slice(0,k==='checklist'?4000:2000)]));
const message=(e:{code?:string;message:string})=>e.code==='42501'?'Your role does not allow this action. Claim an available task before starting work.':e.code==='40001'?'This task changed. Refresh and review its latest progress.':e.code==='23505'?'This room already has active cleaning work, or this action is already recorded. Refresh and open the existing task.':['22023','P0002'].includes(e.code??'')?e.message:'Couldn’t save this task. Refresh and try again.';
const refresh=(pid:string)=>{revalidatePath('/dashboard');revalidatePath(`/p/${pid}/tasks`,'layout');revalidatePath(`/p/${pid}/requests`,'layout');revalidatePath(`/p/${pid}/inventory`,'layout');revalidatePath(`/p/${pid}/reservations`,'layout');};
export async function createTask(_:TaskState,fd:FormData):Promise<TaskState>{
 const pid=field(fd,'pid'),request=field(fd,'request'),fields=snapshot(fd);const fail=(error:string)=>({error,fields});
 if(!validId(pid)||!validId(request))return fail('Reload this form.');
 if(fields.title.length<2||fields.title.length>200||fields.description.length>2000)return fail('Use a title of 2–200 characters and details up to 2000.');
 if(!taskKinds.includes(fields.kind as typeof taskKinds[number])||!taskPriorities.includes(fields.priority as typeof taskPriorities[number]))return fail('Choose a work type and priority.');
 if(!validTarget(fields.target_minutes))return fail('Enter a target of 1–10080 whole minutes, or leave it blank.');
 for(const k of ['assignee','unit','department'])if(fields[k]&&!validId(fields[k]))return fail('Choose a valid room, department, and teammate.');
 const checklist=parseChecklist(field(fd,'checklist'));if(!checklist)return fail('Use up to 20 checklist lines, each up to 160 characters.');
 const db=await createClient(),{data,error}=await db.rpc('task_create_advanced',{p_property:pid,p_request:request,p_details:{...fields,checklist}});if(error)return fail(message(error));refresh(pid);redirect(`/p/${pid}/tasks/${data}?notice=created`);
}
export async function taskOperation(_:TaskState,fd:FormData):Promise<TaskState>{
 const pid=field(fd,'pid'),id=field(fd,'id'),request=field(fd,'request'),op=field(fd,'operation'),version=Number(field(fd,'version')),fields=snapshot(fd);const fail=(error:string)=>({error,fields});
 if(!validId(pid)||!validId(id)||!validId(request)||!Number.isInteger(version)||version<1)return fail('Reload this task.');
 if(!['status','claim','assign','triage','comment','check','add_check','remove_check'].includes(op))return fail('Choose a valid action.');
 const details:Record<string,string>={};
 if(op==='status'){details.status=field(fd,'status');details.reason=field(fd,'reason');if(!['open','in_progress','done','cancelled'].includes(details.status))return fail('Choose a valid status.');if(details.reason.length>500)return fail('Keep the reason under 500 characters.');}
 if(op==='assign'){details.assignee=field(fd,'assignee');if(details.assignee&&!validId(details.assignee))return fail('Choose an eligible teammate.');}
 if(op==='triage'){details.priority=field(fd,'priority');details.deadline=field(fd,'deadline');details.target_minutes=field(fd,'target_minutes');if(!taskPriorities.includes(details.priority as typeof taskPriorities[number])||!['keep','set','clear'].includes(details.deadline)||details.deadline==='set'&&(!details.target_minutes||!validTarget(details.target_minutes)))return fail('Choose a priority and valid response target.');}
 if(op==='comment'){details.body=field(fd,'body');if(!details.body||details.body.length>2000)return fail('Write a comment of 1–2000 characters.');}
 if(op==='check'||op==='remove_check'){details.item=field(fd,'item');if(!validId(details.item))return fail('Checklist item not found.');if(op==='check'){details.done=field(fd,'done');if(!['true','false'].includes(details.done))return fail('Choose a checklist state.');}}
 if(op==='add_check'){details.label=field(fd,'label');if(!details.label||details.label.length>160)return fail('Use an item label of 1–160 characters.');}
 const db=await createClient(),{error}=await db.rpc('task_action',{p_property:pid,p_id:id,p_version:version,p_request:request,p_action:op,p_details:details});if(error)return fail(message(error));refresh(pid);redirect(`/p/${pid}/tasks/${id}?notice=${op}`);
}

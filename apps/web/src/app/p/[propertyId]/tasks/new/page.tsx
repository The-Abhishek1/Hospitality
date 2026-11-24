import Link from 'next/link';
import {randomUUID} from 'node:crypto';
import {createClient} from '@/lib/supabase/server';
import {NewTaskForm} from '@/components/tasks/new-task-form';
import {type TaskSetup} from '@/lib/tasks';
import '@/components/service-desk/service-desk.css';
import '@/components/tasks/tasks.css';
export const metadata={title:'New task · Hospitality'};
export default async function NewTaskPage({params,searchParams}:{params:Promise<{propertyId:string}>;searchParams:Promise<{unit?:string;kind?:string}>}){
 const{propertyId:pid}=await params,p=await searchParams,db=await createClient(),{data,error}=await db.rpc('task_setup',{p_property:pid});
 if(error)return <section><h2>Task management access required</h2><p>Ask a task manager to create and assign this work.</p><Link href={`/p/${pid}/tasks`}>Back to tasks</Link></section>;
 return <div className="service-workspace tasks-workspace"><div className="sr-subheading"><div><Link href={`/p/${pid}/tasks`}>← Task workspace</Link><h2>New task</h2><p>Choose the room, work and teammate.</p></div></div><NewTaskForm pid={pid} request={randomUUID()} setup={data as TaskSetup} unit={p.unit} kind={p.kind}/></div>;
}

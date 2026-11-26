import {randomUUID} from 'node:crypto';
import {ChecklistControl} from './task-forms';
import type {TaskDetail} from '@/lib/tasks';
export function GroupedChecklist({pid,detail:d}:{pid:string;detail:TaskDetail}){
 const groups=new Map<string,TaskDetail['checklist']>();
 for(const item of d.checklist){const split=item.label.indexOf(' › '),category=split<0?'General':item.label.slice(0,split);groups.set(category,[...(groups.get(category)??[]),item]);}
 const active=['open','in_progress'].includes(d.task.status);
 return <div>{Array.from(groups,([category,items],index)=><details key={category} open={index===0} className="task-check-category"><summary><strong>{category}</strong><span>{items.filter(x=>x.done).length} / {items.length} done</span></summary><ul className="task-checklist">{items.map(item=><li key={item.id} className={item.done?'is-done':''}><span>{item.label.includes(' › ')?item.label.split(' › ').slice(1).join(' › '):item.label}</span><div>{active&&d.can_work?<ChecklistControl pid={pid} detail={d} request={randomUUID()} item={item}/>:<span className="sr-count">{item.done?'Done':'To do'}</span>}{active&&d.can_manage&&<ChecklistControl pid={pid} detail={d} request={randomUUID()} item={item} remove/>}</div></li>)}</ul></details>)}</div>;
}

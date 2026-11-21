"use client";
import{rolePermissions,type StaffRole}from '@/lib/team';
export function PermissionPreview({selected,roles,full=false}:{selected:string[];roles:StaffRole[];full?:boolean}){
 const permissions=rolePermissions(selected,roles),descriptions=new Map(roles.flatMap(r=>r.permissions.map(p=>[p.key,p.description]as const)));
 if(!full&&selected.some(k=>roles.some(r=>r.key===k&&!r.assignable)))return <p className="sr-alert info">A role key is duplicated in this business. Resolve the role-key conflict before assigning or previewing these roles. Existing effective-permission counts remain visible on the staff page.</p>;
 if(full)return <p className="sr-alert info">Business owners and administrators have full access to every current and future hotel. Property roles do not limit that business-wide access.</p>;
 return <details className="team-permission-preview"><summary>{permissions.length?`${permissions.length} effective permissions · Review access`:'No operational permissions selected'}</summary>{permissions.length>0?<><p>Selected roles combine their permissions for this hotel.</p><ul>{permissions.map(p=><li key={p}><strong>{descriptions.get(p)??p}</strong><code>{p}</code></li>)}</ul></>:<p>No hotel access is granted when all property roles are cleared.</p>}</details>;
}
export function RolePicker({roles,selected,onChange,name}:{roles:StaffRole[];selected:string[];onChange:(keys:string[])=>void;name?:string}){
 return <div className="team-role-picker">{roles.map(r=><label key={r.id} className={selected.includes(r.key)?'selected':''}><input type="checkbox" name={name} value={r.key} checked={selected.includes(r.key)} disabled={!r.assignable} onChange={e=>onChange(e.target.checked?[...selected,r.key]:selected.filter(k=>k!==r.key))}/><span><strong>{r.name}{r.custom?' · Custom':''}</strong><small>{r.assignable?`${r.permissions.length} permissions`:'Ambiguous role key · unavailable for new assignments'}</small></span></label>)}</div>;
}

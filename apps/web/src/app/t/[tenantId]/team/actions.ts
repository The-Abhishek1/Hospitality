"use server";
import{redirect}from 'next/navigation';import{revalidatePath}from 'next/cache';import{createClient}from '@/lib/supabase/server';import{validId}from '@/lib/reservations';import{parseGrants}from '@/lib/team';
export type TeamState={error?:string;fields?:Record<string,string>};
const f=(fd:FormData,k:string)=>String(fd.get(k)??'').trim();
const snapshot=(fd:FormData)=>Object.fromEntries(['email','business_role','grants','days','reason','operation','confirm_email','property_id'].map(k=>[k,f(fd,k)]));
const friendly=(e:{code?:string;message:string})=>e.code==='42501'?'Your business role does not permit this action. Only owners manage business administrators and owners.':e.code==='40001'?'This member or invitation changed. Refresh and review the latest access.':e.code==='23505'?'This address already has a pending invitation. Review or renew that invitation.':e.code==='23514'?'The business must keep at least one owner.':['22023','P0002'].includes(e.code??'')?e.message:'Couldn’t save this team change. Refresh and try again.';
function refresh(tid:string){revalidatePath(`/t/${tid}/team`,'layout');revalidatePath('/dashboard');revalidatePath('/properties');revalidatePath('/','layout');}
export async function inviteStaff(_:TeamState,fd:FormData):Promise<TeamState>{
 const tid=f(fd,'tid'),request=f(fd,'request'),fields=snapshot(fd),fail=(error:string)=>({error,fields}),email=f(fd,'email').toLowerCase(),role=f(fd,'business_role'),grants=parseGrants(f(fd,'grants')),days=f(fd,'days');
 if(!validId(tid)||!validId(request)||!/^\d{1,2}$/.test(days)||Number(days)<1||Number(days)>30)return fail('Use a valid business and invitation validity of 1–30 days.');
 if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)||email.length>254||!['admin','member'].includes(role)||!grants||grants.some(g=>!validId(g.property_id)))return fail('Check the email address, business role, and hotel roles.');
 if(f(fd,'confirm')!=='yes')return fail('Review and confirm the access this invitation grants.');
 const db=await createClient(),{data,error}=await db.rpc('team_action',{p_tenant:tid,p_request:request,p_action:'invite',p_target:null,p_version:null,p_details:{email,business_role:role,grants:role==='admin'?[]:grants,days:Number(days)}});if(error)return fail(friendly(error));refresh(tid);redirect(`/t/${tid}/team/invitations/${data}?notice=created&property=${encodeURIComponent(f(fd,'active_property'))}`);
}
export async function teamOperation(_:TeamState,fd:FormData):Promise<TeamState>{
 const tid=f(fd,'tid'),request=f(fd,'request'),target=f(fd,'target'),op=f(fd,'operation'),version=Number(f(fd,'version')),fields=snapshot(fd),roles=fd.getAll('roles').map(String);fields.roles=JSON.stringify(roles);const fail=(error:string)=>({error,fields});
 if(!validId(tid)||!validId(request)||!validId(target)||!Number.isInteger(version)||version<1||!['access','role','remove','renew','revoke'].includes(op))return fail('Reload this team form.');
 if(f(fd,'confirm')!=='yes')return fail('Review and confirm this access change.');const details:Record<string,unknown>={};
 if(['access','role','remove','revoke'].includes(op)){if(f(fd,'reason').length<3||f(fd,'reason').length>500)return fail('Give a reason of 3–500 characters.');details.reason=f(fd,'reason');}
 const db=await createClient();
 if(op==='access'){const property=f(fd,'property_id');if(!validId(property)||roles.length>30||roles.some(r=>!r||r.length>80)||new Set(roles).size!==roles.length)return fail('Choose a hotel and unique property roles.');details.property_id=property;details.roles=roles;}
 if(op==='role'){details.business_role=f(fd,'business_role');if(!['owner','admin','member'].includes(String(details.business_role)))return fail('Choose a valid business role.');}
 if(['role','remove'].includes(op)){const{data,error}=await db.rpc('team_member_detail',{p_tenant:tid,p_user:target});if(error)return fail(friendly(error));const expected=data.member.email??data.member.name??target;if(f(fd,'confirm_email').toLowerCase()!==String(expected).trim().toLowerCase())return fail('Enter the displayed staff email or name exactly to confirm the target.');}
 if(op==='renew'){const days=f(fd,'days');if(!/^\d{1,2}$/.test(days)||Number(days)<1||Number(days)>30)return fail('Use 1–30 days for the renewed invitation.');details.days=Number(days);}
 const{error}=await db.rpc('team_action',{p_tenant:tid,p_request:request,p_action:op,p_target:target,p_version:version,p_details:details});if(error)return fail(friendly(error));refresh(tid);
 const{data:{user}}=await db.auth.getUser();if(user?.id===target&&(op==='remove'||op==='role'&&details.business_role==='member'))redirect('/dashboard');
 const property=encodeURIComponent(f(fd,'active_property'));if(op==='remove')redirect(`/t/${tid}/team?notice=removed&property=${property}`);
 redirect(`/t/${tid}/team/${['renew','revoke'].includes(op)?'invitations':'members'}/${target}?notice=${op}&property=${property}`);
}

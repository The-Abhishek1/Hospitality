"use server";
import {redirect}from 'next/navigation';
import {revalidatePath}from 'next/cache';
import {createClient}from '@/lib/supabase/server';
import {validId,validDay,stayNights}from '@/lib/reservations';
import {inventoryMoney,validAdjustment}from '@/lib/inventory';
export type InventoryState={error?:string;fields?:Record<string,string>};
const field=(fd:FormData,k:string)=>String(fd.get(k)??'').trim();
const friendly=(e:{code?:string;message:string})=>e.code==='42501'?'Inventory management access is required.':e.code==='40001'?'This item changed. Refresh and review the latest settings.':e.code==='23P01'?'This room is already reserved or blocked for part of that date range. Choose another room or dates.':e.code==='23505'?'That room name, room-type name, rate code, or action already exists in this hotel.':['22023','P0002'].includes(e.code??'')?e.message:'Couldn’t save this change. Check the details and try again.';
export async function saveInventory(_:InventoryState,fd:FormData):Promise<InventoryState>{
 const pid=field(fd,'pid'),request=field(fd,'request'),section=field(fd,'section'),id=field(fd,'id'),version=Number(field(fd,'version'));
 const fields=Object.fromEntries(['name','kind','capacity','base_rate','description','type_id','floor','notes','code','adjustment','unit_id','from','to','reason'].map(k=>[k,field(fd,k)]));fields.active=field(fd,'active')==='yes'?'true':'false';
 const fail=(error:string)=>({error,fields});if(!validId(pid)||!validId(request)||(id&&!validId(id))||id&&(!Number.isInteger(version)||version<1)||!['rooms','types','rates','blocks','release'].includes(section))return fail('Reload this inventory form.');
 if(['rooms','types','rates'].includes(section)&&(!fields.name||fields.name.length>120))return fail('Enter a name of 1–120 characters.');
 if(section==='types'){if(!['room','suite','bed','entire_property'].includes(fields.kind)||!/^\d{1,3}$/.test(fields.capacity)||Number(fields.capacity)<1||Number(fields.capacity)>100||!inventoryMoney(fields.base_rate)||fields.description.length>2000)return fail('Check the room kind, capacity (1–100), non-negative rate, and description (up to 2000 characters).');fields.base_rate=inventoryMoney(fields.base_rate)!;}
 if(section==='rooms'&&(!validId(fields.type_id)||fields.floor.length>50||fields.notes.length>1000))return fail('Choose a room type. Keep floor under 50 characters and room notes under 1000.');
 if(section==='rates'&&(!/^[A-Za-z0-9][A-Za-z0-9_-]{0,29}$/.test(fields.code)||!validAdjustment(fields.adjustment)||fields.description.length>500))return fail('Use a valid rate code, an adjustment from -100% to 1000%, and a description up to 500 characters.');
 if(section==='blocks'&&(!validId(fields.unit_id)||!validDay(fields.from)||!validDay(fields.to)||stayNights(fields.from,fields.to)<1||stayNights(fields.from,fields.to)>365))return fail('Choose a room and a block of 1–365 nights.');
 if(['blocks','release'].includes(section)&&(fields.reason.length<3||fields.reason.length>500))return fail('Give a reason of 3–500 characters.');
 if(section==='release'&&field(fd,'confirm')!=='yes')return fail('Confirm the release before saving.');
 const db=await createClient(),{data,error}=await db.rpc('inventory_save',{p_property:pid,p_request:request,p_section:section,p_id:id||null,p_version:id?version:null,p_details:fields});if(error)return fail(friendly(error));
 for(const path of ['inventory','tasks','reservations'])revalidatePath(`/p/${pid}/${path}`,'layout');revalidatePath('/dashboard');
 redirect(`/p/${pid}/inventory/${section==='release'?'blocks':section}/${data}?notice=saved`);
}

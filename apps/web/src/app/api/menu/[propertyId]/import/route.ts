import {NextRequest,NextResponse} from 'next/server';
import {createHash} from 'node:crypto';
import {revalidatePath} from 'next/cache';
import {createClient} from '@/lib/supabase/server';
import {buildMenuImport} from '@/lib/menu-import';
export const runtime='nodejs';
export const maxDuration=60;
const reply=(body:object,status=200)=>NextResponse.json(body,{status,headers:{'Cache-Control':'no-store'}});
function sizeId(request:string,name:string,size:string){const h=createHash('sha256').update(`${request}:${name.toLowerCase()}:${size.toLowerCase()}`).digest('hex');return`${h.slice(0,8)}-${h.slice(8,12)}-5${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}`;}
export async function POST(req:NextRequest,{params}:{params:Promise<{propertyId:string}>}){
 const origins=new Set([req.nextUrl.origin]);try{if(process.env.APP_URL)origins.add(new URL(process.env.APP_URL).origin);}catch{}
 if(!origins.has(req.headers.get('origin')??''))return reply({error:'Open this hotel app to import a menu.'},403);
 const{propertyId:pid}=await params,db=await createClient(),{data:{user}}=await db.auth.getUser();if(!user)return reply({error:'Sign in again.'},401);
 const access=await db.rpc('food_menu_access',{p_property:pid});if(access.error)return reply({error:'Menu management access required.'},403);
 if(Number(req.headers.get('content-length'))>700000)return reply({error:'The menu data is too large. Split the file into smaller imports.'},413);
 try{
  const chunks:Uint8Array[]=[];let size=0;const reader=req.body?.getReader();
  if(reader)while(true){const part=await reader.read();if(part.done)break;size+=part.value.byteLength;if(size>700000){await reader.cancel();return reply({error:'The menu data is too large. Split the file into smaller imports.'},413);}chunks.push(part.value);}
  const raw=Buffer.concat(chunks).toString('utf8');
  const input=JSON.parse(raw);if(!input||!['preview','import'].includes(input.action)||typeof input.request!=='string'||!/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(input.request)||!['skip','error'].includes(input.duplicates))return reply({error:'Preview the file and choose how to handle existing items.'},400);
  const plan=buildMenuImport(input.rows);if(plan.issues.length)return reply({error:'Correct the spreadsheet rows below and upload the file again.',issues:plan.issues},422);
  const items=plan.items.map(item=>({...item,details:{...item.details,variants:item.details.variants.map(v=>({...v,id:sizeId(input.request,item.details.name,v.label)}))}}));
  if(input.action==='preview'){
   const{data,error}=await db.rpc('food_menu_import_preview',{p_property:pid,p_items:items});if(error)return reply({error:['22023','42501'].includes(error.code)?error.message:'Could not preview this menu. Try again.'},400);
   return reply({preview:data,source_rows:plan.rows});
  }
  const{data,error}=await db.rpc('food_menu_import',{p_property:pid,p_request:input.request,p_items:items,p_duplicates:input.duplicates});
  if(error)return reply({error:['22023','23505','40001','42501'].includes(error.code)?error.message:'Could not complete the import. Retry with the same file; duplicate items will not be created.'},400);
  revalidatePath(`/p/${pid}/orders/menu`);revalidatePath(`/p/${pid}/orders/new`);return reply({result:data});
 }catch{return reply({error:'Could not read the menu data. Choose the file and preview it again.'},400);}
}

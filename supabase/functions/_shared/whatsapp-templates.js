// Only body parameters and a static footer are supported by the automation transport.
export function normalizeTemplate(t){
 const components=Array.isArray(t.components)?t.components:[],raw=components.find(c=>c.type==='BODY')?.text,body=typeof raw==='string'?raw:'';
 const names=[...body.matchAll(/\{\{\s*([a-z_][a-z0-9_]*|[1-9][0-9]*)\s*\}\}/g)].map(x=>x[1]);
 const unique=[...new Set(names)],positional=unique.every(x=>/^\d+$/.test(x)),named=unique.every(x=>/^[a-z_]/.test(x));
 const ordered=positional?unique.sort((a,b)=>Number(a)-Number(b)):unique;
 const supported=typeof body==='string'&&body.length>0&&body.length<=1024&&unique.length<=15&&(positional||named)&&(!positional||ordered.every((x,i)=>Number(x)===i+1))&&
 components.filter(c=>c.type==='BODY').length===1&&components.every(c=>c.type==='BODY'||c.type==='FOOTER'&&!String(c.text??'').includes('{{'))&&
 !body.replace(/\{\{\s*([a-z_][a-z0-9_]*|[1-9][0-9]*)\s*\}\}/g,'').includes('{{')&&['UTILITY','MARKETING'].includes(t.category);
 return {provider_id:String(t.id),name:t.name,language:t.language,category:t.category?.toLowerCase(),provider_status:t.status,body,parameter_names:ordered,supported,definition:{components,parameter_format:t.parameter_format??(named&&unique.length?'NAMED':'POSITIONAL'),category:t.category}};
}
export async function fetchTemplates(waba,token,version,fetcher=fetch){
 const rows=[];let after='';
 for(let page=0;page<20;page++){
  const url=`https://graph.facebook.com/${version}/${waba}/message_templates?fields=id,name,language,status,category,parameter_format,components&limit=100${after?'&after='+encodeURIComponent(after):''}`;
  const r=await fetcher(url,{headers:{Authorization:`Bearer ${token}`},signal:AbortSignal.timeout(20000)});const d=await r.json();
  if(!r.ok||d.error||!Array.isArray(d.data))throw Error(`Template sync rejected (code ${d.error?.code??r.status}).`);
  rows.push(...d.data.map(normalizeTemplate));if(!d.paging?.next)return rows;
  after=d.paging?.cursors?.after;if(!after)throw Error('Incomplete template pagination. No template statuses changed.');
 }
 throw Error('Template directory exceeds supported pagination. No template statuses changed.');
}

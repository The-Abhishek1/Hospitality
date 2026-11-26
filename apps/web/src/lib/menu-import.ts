export const menuImportColumns=['name','category','price','tax_percent','food_type','served_in','size','description','dietary_notes','prep_minutes','available'] as const;
export type ImportIssue={row:number;message:string};
export type MenuImportItem={row:number;details:{name:string;category:string;price:string;tax:string;dietary_type:string;service_scope:string;pricing_mode:'single'|'sizes';description:string;dietary_notes:string;prep_minutes:string;active:boolean;variants:{label:string;price:string}[]}};
export const menuImportLimits={bytes:2*1024*1024,rows:500,items:200};

// RFC-style quoted CSV, including commas, escaped quotes and multiline descriptions.
export function parseMenuCsv(input:string):string[][]{
 const text=input.replace(/^\uFEFF/,''),first=text.split(/\r?\n/,1)[0],delimiter=first.includes(';')&&!first.includes(',')?';':',';
 const rows:string[][]=[];let row:string[]=[],cell='',quoted=false,closed=false;
 const field=()=>{row.push(cell);cell='';closed=false;};
 const record=()=>{field();rows.push(row);row=[];if(rows.length>menuImportLimits.rows+1)throw Error('Use up to 500 data rows per file.');};
 for(let i=0;i<text.length;i++){
  const ch=text[i];
  if(quoted){if(ch==='"'){if(text[i+1]==='"'){cell+='"';i++;}else{quoted=false;closed=true;}}else cell+=ch;continue;}
  if(ch===delimiter){field();continue;}
  if(ch==='\n'||ch==='\r'){if(ch==='\r'&&text[i+1]==='\n')i++;record();continue;}
  if(ch==='"'){if(cell!==''||closed)throw Error('Check CSV quotation marks. Download the template and save as CSV UTF-8.');quoted=true;continue;}
  if(closed){if(ch===' '||ch==='\t')continue;throw Error('Unexpected text after a quoted CSV value.');}
  cell+=ch;
 }
 if(quoted)throw Error('A quoted CSV value is not closed.');
 if(cell!==''||row.length||closed)record();return rows;
}

export function buildMenuImport(input:unknown):{items:MenuImportItem[];issues:ImportIssue[];rows:number}{
 const issues:ImportIssue[]=[],items:MenuImportItem[]=[];
 const issue=(row:number,message:string)=>{if(issues.length<100)issues.push({row,message});};
 if(!Array.isArray(input)||input.length<2||input.length>menuImportLimits.rows+1||!input.every(Array.isArray))return{items,issues:[{row:1,message:'Use a header row and 1–500 data rows.'}],rows:0};
 const aliases:Record<string,string>={tax:'tax_percent',dietary_type:'food_type',service_scope:'served_in',variant:'size',active:'available'};
 const headers=input[0].map((value:unknown)=>{const k=String(value??'').replace(/^\uFEFF/,'').trim().toLowerCase().replace(/[ -]+/g,'_');return aliases[k]??k;});
 for(const column of ['name','category','price'])if(!headers.includes(column))issue(1,`Missing column: ${column}. Use the downloadable template.`);
 const seen=new Set<string>();for(const h of headers){if(!h)continue;if(seen.has(h))issue(1,`Column ${h} appears twice.`);seen.add(h);if(!(menuImportColumns as readonly string[]).includes(h))issue(1,`Unknown column: ${h}. Use the template column names.`);}
 if(issues.length)return{items,issues,rows:0};
 const groups=new Map<string,MenuImportItem>();let rowCount=0;
 for(let i=1;i<input.length;i++){
  const row=input[i] as unknown[],line=i+1;if(row.every(v=>v===null||v===undefined||String(v).trim()===''))continue;rowCount++;
  const prior=issues.length;
  if(row.length>30||row.some(v=>v!==null&&v!==undefined&&!['string','number','boolean'].includes(typeof v))){issue(line,'Use plain text, numbers and TRUE/FALSE values.');continue;}
  if(row.some((v,index)=>(index>=headers.length||!headers[index])&&v!==null&&v!==undefined&&String(v).trim()!==''))issue(line,'A value has no column heading.');
  const value=(key:string)=>String(row[headers.indexOf(key)]??'').trim();
  const name=value('name'),category=value('category'),price=value('price'),tax=value('tax_percent')||'0',size=value('size'),description=value('description'),notes=value('dietary_notes'),prep=value('prep_minutes');
  if(name.length<2||name.length>120)issue(line,'Item name must contain 2–120 characters.');
  if(category.length<2||category.length>80)issue(line,'Category must contain 2–80 characters.');
  if(!/^\d{1,10}(\.\d{1,2})?$/.test(price))issue(line,'Price must be a non-negative number with up to two decimals, without currency symbols.');
  if(!/^\d{1,3}(\.\d{1,2})?$/.test(tax)||Number(tax)>100)issue(line,'Tax percent must be between 0 and 100, with up to two decimals.');
  if(size.length>40)issue(line,'Size must be no longer than 40 characters.');
  if(description.length>800||notes.length>200)issue(line,'Description is limited to 800 characters; dietary notes to 200.');
  if(prep&&(!/^\d{1,3}$/.test(prep)||Number(prep)<1||Number(prep)>240))issue(line,'Preparation time must be 1–240 minutes, or blank.');
  const dietKey=value('food_type').toLowerCase().replace(/[ -]+/g,'_'),serviceKey=value('served_in').toLowerCase().replace(/[ -]+/g,'_');
  const diets:Record<string,string>={'':'not_specified',veg:'veg',vegetarian:'veg',non_veg:'non_veg',nonveg:'non_veg',non_vegetarian:'non_veg',egg:'egg',vegan:'vegan',not_specified:'not_specified'};
  const services:Record<string,string>={'':'both',both:'both',restaurant:'restaurant',room_service:'room_service',roomservice:'room_service'};
  if(!Object.hasOwn(diets,dietKey))issue(line,'Food type must be veg, non_veg, egg, vegan or not_specified.');
  if(!Object.hasOwn(services,serviceKey))issue(line,'Served in must be restaurant, room_service or both.');
  const availability=value('available').toLowerCase();if(!['','true','false','yes','no','1','0'].includes(availability))issue(line,'Available must be TRUE or FALSE; blank means unavailable.');
  if(prior!==issues.length)continue;
  const details:MenuImportItem['details']={name,category,price:size?'0':price,tax,dietary_type:diets[dietKey],service_scope:services[serviceKey],pricing_mode:size?'sizes':'single',description,dietary_notes:notes,prep_minutes:prep,active:['true','yes','1'].includes(availability),variants:size?[{label:size,price}]:[]};
  const existing=groups.get(name.toLowerCase());
  if(existing){
   if(!size||existing.details.pricing_mode!=='sizes'){issue(line,`Duplicate item “${name}”. Repeat a name only for different sizes.`);continue;}
   const metadata=(d:typeof details)=>JSON.stringify({...d,name:d.name.toLowerCase(),category:d.category.toLowerCase(),variants:[],price:'0'});
   if(metadata(details)!==metadata(existing.details)){issue(line,`Keep category, tax, availability and other details identical for all sizes of “${name}”.`);continue;}
   if(existing.details.variants.some(v=>v.label.toLowerCase()===size.toLowerCase())){issue(line,`Size “${size}” appears twice for “${name}”.`);continue;}
   if(existing.details.variants.length>=12){issue(line,`Use at most 12 sizes for “${name}”.`);continue;}
   existing.details.variants.push({label:size,price});
  }else{const item={row:line,details};groups.set(name.toLowerCase(),item);items.push(item);}
 }
 if(!rowCount)issue(2,'Add at least one menu item.');
 if(items.length>menuImportLimits.items)issue(1,'Import up to 200 distinct items at a time.');
 return{items,issues,rows:rowCount};
}

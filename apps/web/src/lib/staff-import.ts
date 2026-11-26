export const staffColumns=['code','full_name','department','phone','email','joined_on','monthly_salary'];
export type StaffImportRow={code:string;full_name:string;department:string;phone:string;email:string;joined_on:string;monthly_salary:string};
export function staffImport(input:unknown){
 const rows:StaffImportRow[]=[],errors:string[]=[];
 if(!Array.isArray(input)||input.length<2||input.length>201||!input.every(Array.isArray))return{rows,errors:['Use a header and 1–200 employees.']};
 const headers=input[0].map((v:unknown)=>String(v??'').replace(/^\uFEFF/,'').trim().toLowerCase());
 if(headers.length!==staffColumns.length||new Set(headers).size!==headers.length||headers.some((h:string)=>!staffColumns.includes(h)))return{rows,errors:['Use the template headings: '+staffColumns.join(', ')]};
 const seen=new Set<string>();
 for(let i=1;i<input.length;i++){
  const values=input[i] as unknown[];if(values.every(v=>v==null||v===''))continue;
  const row=Object.fromEntries(headers.map((h:string,j:number)=>[h,String(values[j]??'').trim()])) as StaffImportRow;
  const iso=/^\d{4}-\d{2}-\d{2}$/.test(row.joined_on)?row.joined_on:/^\d{2}-\d{2}-\d{4}$/.test(row.joined_on)?row.joined_on.split('-').reverse().join('-'):'';
  const date=new Date(iso+'T12:00:00Z');row.joined_on=iso;
  if(row.code.length<1||row.code.length>30||row.full_name.length<2||row.full_name.length>120||row.department.length>80||row.phone.length>40||row.email.length>254||!iso||!Number.isFinite(date.getTime())||date.toISOString().slice(0,10)!==iso||row.monthly_salary&&!/^\d{1,9}(\.\d{1,2})?$/.test(row.monthly_salary))errors.push(`Row ${i+1}: check code, name, joining date (DD-MM-YYYY) and numeric salary.`);
  if(seen.has(row.code.toLowerCase()))errors.push(`Row ${i+1}: duplicate staff code ${row.code}.`);seen.add(row.code.toLowerCase());rows.push(row);
 }
 if(!rows.length)errors.push('Add at least one employee.');return{rows,errors};
}

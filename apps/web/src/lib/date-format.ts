// Keep ISO dates at API/database boundaries; use one explicit display format.
export function displayDay(value:string){
 const match=/^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
 return match?`${match[3]}-${match[2]}-${match[1]}`:value;
}
export function inputDay(value:string){
 const match=/^(\d{2})-(\d{2})-(\d{4})$/.exec(value);
 if(!match)return '';
 const iso=`${match[3]}-${match[2]}-${match[1]}`,date=new Date(`${iso}T12:00:00Z`);
 return Number.isFinite(date.getTime())&&date.toISOString().slice(0,10)===iso?iso:'';
}
export function displayDateTime(value:string|Date|number,timeZone='UTC'){
 const date=new Date(value);if(!Number.isFinite(date.getTime()))return '—';
 const parts=new Intl.DateTimeFormat('en-GB',{day:'2-digit',month:'2-digit',year:'numeric',timeZone}).formatToParts(date);
 const get=(type:string)=>parts.find(p=>p.type===type)?.value;
 return `${get('day')}-${get('month')}-${get('year')} · ${new Intl.DateTimeFormat('en',{hour:'numeric',minute:'2-digit',hour12:true,timeZone}).format(date)}`;
}

export const guestTasks=['documents','food','bill','stay','services','arrival','guide','checkin','checkout']as const;
export type GuestTask=typeof guestTasks[number];
export const taskTitle:Record<GuestTask,string>={documents:'Identity documents',food:'Order food',bill:'Your bill',stay:'Your stay',services:'Request a service',arrival:'Arrival details',guide:'Hotel information',checkin:'Request check-in',checkout:'Request checkout'};
export const isGuestTask=(value:unknown):value is GuestTask=>typeof value==='string'&&guestTasks.includes(value as GuestTask);
export function legacyGuestTask(view?:string,hash?:string,intent?:string):GuestTask{const requested=intent==='checkin'||intent==='checkout'?intent:view||hash?.replace(/^#/,'');return isGuestTask(requested)?requested:'stay';}
export function guestTaskPath(token:string,task:GuestTask){return `/s/${token}/${task}`;}
export function publicGuestPath(path:string){return path==='/api/guest-documents'||/^\/s(?:\/|$)/.test(path);}
export function documentProgress(documents:{doc_type:string;status:string}[],required=1){const identity=documents.filter(d=>['id_proof','passport','visa','aadhaar','pan'].includes(d.doc_type)),approved=identity.filter(d=>d.status==='approved').length,submitted=identity.filter(d=>['uploaded','clean','image_ready','approved'].includes(d.status)).length,pending=identity.some(d=>['uploaded','clean','image_ready'].includes(d.status));return{approved,submitted,required,can_upload:submitted<required,state:approved>=required&&!pending?'approved':submitted>=required?'review':identity.some(d=>['rejected','infected','image_invalid'].includes(d.status))?'replacement':'upload'};}

export function documentWhatsAppReturn(number:unknown){return typeof number==='string'&&/^[1-9][0-9]{7,14}$/.test(number)?`https://wa.me/${number}`:null;}

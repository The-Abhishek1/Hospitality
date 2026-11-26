export type SetupSlot={slot:string;state:string;last_error:string|null;kind:string};
export type WhatsAppReadiness={title:string;description:string;tone:'ready'|'waiting'|'off'|'attention';approved:number;pending:number;issues:number;customized:number;paused:number|null;configured:boolean;enabled:boolean};
export function whatsappReadiness(input:{connected:boolean;configured:boolean;enabled:boolean;workerReady:boolean;slots:SetupSlot[];paused:number|null;setupError:string|null}):WhatsAppReadiness{
 const approved=input.slots.filter(s=>s.state==='ready').length,customized=input.slots.filter(s=>s.state==='customized').length;
 const issues=input.slots.filter(s=>s.state==='needs_attention'||Boolean(s.last_error)).length;
 const pending=input.slots.filter(s=>['queued','awaiting_approval'].includes(s.state)&&!s.last_error).length;
 const status:WhatsAppReadiness={title:'',description:'',tone:'off',approved,pending,issues,customized,paused:input.paused,configured:input.configured,enabled:input.enabled};
 if(!input.connected)return{...status,title:'Connect your hotel’s number',description:'Start with step 1. Your existing messages and settings stay saved.'};
 if(!input.configured)return{...status,title:'Finish message setup',description:'Complete step 2 to submit the default messages and assign them to events and menu services.'};
 if(!input.enabled)return{...status,title:'Guest messaging is off',description:'Your templates stay saved. Turn on step 3 when you want automatic messages and guest replies.'};
 if(!input.workerReady)return{...status,tone:'attention',title:'On · sending service needs attention',description:'Guest messaging is switched on, but sending has no recent successful check. Review Activity or contact your platform administrator.'};
 if(input.setupError||issues)return{...status,tone:'attention',title:'On · some messages need attention',description:'Ready messages can run. Review the flagged templates in step 2; affected messages cannot send yet.'};
 if(pending)return{...status,tone:'waiting',title:'On · messages are being approved',description:`${approved} default messages are ready; ${pending} are being prepared or reviewed. Approved messages are assigned automatically. Guest replies use the available menu.`};
 return{...status,tone:'ready',title:input.paused?'On · some chats are paused':'Guest messaging is on',description:input.paused?'Your hotel setup is on. Chats handed to reception stay paused until a staff member resumes them below.':'Ready event messages send after eligible hotel actions. Guests send Hi, Hello or MENU to get help.'};
}

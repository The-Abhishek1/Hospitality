'use server';
export type StudioState={error?:string};
export async function saveStudio(_:StudioState,_fd:FormData):Promise<StudioState>{return{error:'This draft workspace has been retired. Open WhatsApp → Templates or Guest menu.'};}

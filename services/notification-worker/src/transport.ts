export type SendJob={phone_number_id:string;credentials_ref:string;wa_contact_id:string;msg_type:string;msg_body:string|null;template_name:string|null;template_language:string|null};
export class DeliveryError extends Error{constructor(message:string,readonly retryable=false,readonly uncertain=false){super(message);}}
export async function send(job:SendJob,token:string|undefined,graph:string,fetcher:typeof fetch=fetch):Promise<string>{
 if(!token)throw new DeliveryError(`Missing credentials for reference ${job.credentials_ref}.`);
 const payload=job.msg_type==='template'?{messaging_product:'whatsapp',to:job.wa_contact_id,type:'template',template:{name:job.template_name,language:{code:job.template_language??'en'}}}:{messaging_product:'whatsapp',to:job.wa_contact_id,type:'text',text:{body:job.msg_body}};
 let res:Response;
 try{res=await fetcher(`${graph}/${job.phone_number_id}/messages`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(payload),signal:AbortSignal.timeout(20000)});}
 catch{throw new DeliveryError('Delivery outcome unknown after a network error or timeout. Check provider status before sending again.',false,true);}
 const json=await res.json().catch(()=>null) as {error?:{message?:string};messages?:{id?:string}[]}|null;
 if(!res.ok)throw new DeliveryError(json?.error?.message??`Provider HTTP ${res.status}`,res.status===429||res.status>=500);
 const id=json?.messages?.[0]?.id;if(!id)throw new DeliveryError('Provider accepted the request without a message ID. Verify delivery before sending again.',false,true);
 return id;
}

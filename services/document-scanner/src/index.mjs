import {createClient} from '@supabase/supabase-js';
import {scan,ping,MAX_BYTES} from './clamav.mjs';
const {SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,CLAMAV_HOST}=process.env;
if(!SUPABASE_URL||!SUPABASE_SERVICE_ROLE_KEY||!CLAMAV_HOST)throw Error('Configure the server-only Supabase credentials and private ClamAV host.');
const port=Number(process.env.CLAMAV_PORT??3310);if(!Number.isInteger(port)||port<1||port>65535)throw Error('Invalid ClamAV port.');
const db=createClient(SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,{auth:{persistSession:false}});
let stopped=false;process.on('SIGTERM',()=>{stopped=true;});process.on('SIGINT',()=>{stopped=true;});
while(!stopped){
 try{
  let ready=false;try{await ping({host:CLAMAV_HOST,port});ready=true;}catch{}
  const health=await db.rpc('document_scanner_heartbeat',{p_ready:ready});if(health.error||!ready)throw Error('Antivirus or heartbeat unavailable.');
  const jobs=await db.rpc('claim_document_scans',{p_limit:1});if(jobs.error)throw Error('Could not claim documents.');
  for(const job of jobs.data??[]){
   let result='error';
   try{
    if(job.size_bytes<1||job.size_bytes>MAX_BYTES)throw Error('Invalid document size.');
    const file=await db.storage.from('guest-documents').download(job.storage_path);if(file.error||!file.data||file.data.size!==job.size_bytes)throw Error('Document download could not be verified.');
    const bytes=new Uint8Array(await file.data.arrayBuffer());result=await scan(bytes,{host:CLAMAV_HOST,port});
   }catch{console.error('Document remains quarantined; download or antivirus verification failed.',job.document_id);}
   const completed=await db.rpc('complete_document_scan',{p_document:job.document_id,p_lease:job.lease_id,p_result:result});
   if(completed.error||completed.data!==true)console.error('Scan acknowledgment rejected; document remains protected.',job.document_id);
  }
 }catch{console.error('Scanner queue unavailable. Retrying.');}
 await new Promise(resolve=>setTimeout(resolve,Math.max(1000,Math.min(60000,Number(process.env.SCAN_INTERVAL_MS)||5000))));
}

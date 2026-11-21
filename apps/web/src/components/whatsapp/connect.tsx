'use client';
import{useEffect,useRef,useState}from'react';import{useRouter}from'next/navigation';
import{signupEvent}from'../../../../../packages/whatsapp-security/signup-event.mjs';
type FB={init:(options:object)=>void;login:(callback:(response:{authResponse?:{code?:string}})=>void,options:object)=>void};
declare global{interface Window{FB?:FB;fbAsyncInit?:()=>void}}
export function WhatsAppConnect({pid,appId,configId,version,ready,connected,existing}:{pid:string;appId:string;configId:string;version:string;ready:boolean;connected:boolean;existing:boolean}){
 const router=useRouter(),[sdk,setSdk]=useState(false),[busy,setBusy]=useState(false),[prepared,setPrepared]=useState(false),[notice,setNotice]=useState(''),[pin,setPin]=useState('');
 const pending=useRef<{session:string;code?:string;phone?:string;waba?:string;sent?:boolean}|null>(null);
 async function request(body:object){const r=await fetch(`/api/whatsapp/${pid}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const d=await r.json();if(!r.ok)throw Error(d.error||'Setup failed. Start again.');return d;}
 const finish=useRef<()=>void>(()=>{});
 finish.current=()=>{const p=pending.current;if(!p||p.sent||!p.code||!p.phone||!p.waba)return;p.sent=true;
  void request({action:'complete',...p,pin}).then(d=>{setNotice(d.success);setPin('');router.refresh();}).catch(e=>setNotice(e.message)).finally(()=>{pending.current=null;setBusy(false);});
 };
 useEffect(()=>{
  if(!ready)return;
  const init=()=>{window.FB?.init({appId,version,autoLogAppEvents:false,xfbml:false});setSdk(true);};
  if(window.FB)init();else{window.fbAsyncInit=init;if(!document.getElementById('meta-whatsapp-sdk')){const s=document.createElement('script');s.id='meta-whatsapp-sdk';s.src='https://connect.facebook.net/en_US/sdk.js';s.async=true;s.defer=true;s.onerror=()=>setNotice('Meta could not load. Check browser restrictions and refresh.');document.head.appendChild(s);}}
  const listener=(event:MessageEvent)=>{if(!pending.current||pending.current.sent)return;const asset=signupEvent(event.origin,event.data);if(asset){Object.assign(pending.current,asset);finish.current();}};
  window.addEventListener('message',listener);return()=>{window.removeEventListener('message',listener);pending.current=null;};
 },[ready,appId,version,pid]);
 async function prepare(){
  if(!existing&&!/^\d{6}$/.test(pin)){setNotice('Choose your six-digit WhatsApp two-step verification PIN, or enter its existing PIN.');return;}
  if(location.protocol!=='https:'){setNotice('Meta requires HTTPS. Open this page using the HTTPS address approved in the Meta app.');return;}
  setBusy(true);
  try{const d=await request({action:'begin'});pending.current={session:d.session};setPrepared(true);setNotice('Ready. Click Continue with Meta to open the secure setup window.');}
  catch(e){pending.current=null;setNotice(e instanceof Error?e.message:'Could not start setup.');}finally{setBusy(false);}
 }
 function launch(){
  if(!pending.current||!window.FB)return;setPrepared(false);setBusy(true);setNotice('Finish the setup in the Meta popup.');
  // Open directly from this click; awaiting a network request here can trigger popup blockers.
  try{window.FB.login(response=>{
   if(response.authResponse?.code&&pending.current){pending.current.code=response.authResponse.code;finish.current();setTimeout(()=>{if(pending.current&&!pending.current.sent){pending.current=null;setBusy(false);setNotice('Meta did not return both account IDs and authorization. Start again and click Finish.');}},15000);}
   else{pending.current=null;setBusy(false);setNotice('Meta authorization was cancelled. Your saved connection was not changed.');}
  },{config_id:configId,response_type:'code',override_default_response_type:true,extras:{setup:{}}});
  }catch(e){pending.current=null;setBusy(false);setNotice(e instanceof Error?e.message:'Could not open Meta.');}
 }
 async function action(kind:string){if(kind==='disconnect'&&!window.confirm('Disconnect this hotel from Hospitality? Incoming messages and queued replies will stop. Conversation history will stay.'))return;setBusy(true);try{const d=await request({action:kind});setNotice(d.success);router.refresh();}catch(e){setNotice(e instanceof Error?e.message:'Action failed.');}finally{setBusy(false);}}
 return <div className="wa-controls">
 {!existing&&<label>WhatsApp two-step verification PIN<input type="password" inputMode="numeric" autoComplete="off" maxLength={6} value={pin} onChange={e=>setPin(e.target.value.replace(/\D/g,''))}/><small>Six digits. Keep this PIN safe; it is used to register your number and is not saved by Hospitality.</small></label>}
 <div className="wa-buttons"><button className="dash-button" disabled={!ready||!sdk||busy} onClick={prepared?launch:prepare}>{busy?'Working…':prepared?'Continue with Meta':existing?'Reconnect with Meta':'Connect with Meta'}</button>{connected&&<><button className="dash-button dash-secondary" disabled={busy||!ready||prepared} onClick={()=>action('health')}>Check connection</button><button className="dash-button dash-secondary" disabled={busy||prepared} onClick={()=>action('disconnect')}>Disconnect</button></>}</div>
 {busy&&<button className="dash-button dash-secondary" onClick={()=>{if(!pending.current?.sent){pending.current=null;setBusy(false);setNotice('Setup cancelled.');}}}>Cancel waiting</button>}
 {notice&&<p role="status" className="wa-notice">{notice}</p>}
 </div>;
}

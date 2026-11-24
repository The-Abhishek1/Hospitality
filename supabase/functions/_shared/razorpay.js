// Provider transport shared by the web app and the serverless payment worker. No credential/body logging.
export class PaymentError extends Error {constructor(message){super(message);this.name='PaymentError';}}
export function validTestKeys(keyId,secret){return /^rzp_test_[A-Za-z0-9]{6,64}$/.test(keyId??'')&&typeof secret==='string'&&secret.length>=10&&secret.length<=200&&!/[\s\x00-\x1f]/.test(secret);}
export function paymentUrl(value){try{const u=new URL(value);return u.protocol==='https:'&&['rzp.io','rzp.to'].includes(u.hostname)&&!u.username&&!u.password&&!u.hash&&!u.port&&!u.search&&/^\/[A-Za-z0-9/_-]+$/.test(u.pathname);}catch{return false;}}
export function reference(id){if(!/^[a-f0-9-]{36}$/i.test(id))throw new PaymentError('Invalid payment request.');return id.replaceAll('-','');}
export function client(keyId,secret,http=fetch){
 if(!validTestKeys(keyId,secret))throw new PaymentError('Use this hotel’s Razorpay Test Mode keys.');
 const auth='Basic '+btoa(keyId+':'+secret);
 async function api(path,method='GET',body){let response;try{response=await http('https://api.razorpay.com/v1/'+path,{method,redirect:'error',headers:{Authorization:auth,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});}catch{throw new PaymentError('Provider outcome could not be confirmed. We will reconcile this request without creating another link.');}
  if(!response.ok)throw new PaymentError(response.status===401?'Razorpay rejected these Test Mode keys.':`Razorpay request failed (HTTP ${response.status}). Reconcile before retrying.`);
  try{return await response.json();}catch{throw new PaymentError('Provider response could not be confirmed. Reconciliation is required.');}
 }
 async function find(job){if(job.provider_link_id)return api('payment_links/'+encodeURIComponent(job.provider_link_id));const data=await api('payment_links?reference_id='+reference(job.id));if(!Array.isArray(data.payment_links))throw new PaymentError('Payment-link lookup could not be verified.');const links=data.payment_links.filter(link=>link.reference_id===reference(job.id));if(links.length>1)throw new PaymentError('Multiple payment links need staff review.');return links[0]??null;}
 function validate(link,job){if(!link||!/^plink_[A-Za-z0-9]+$/.test(link.id)||link.reference_id!==reference(job.id)||link.amount!==Number(job.amount)||link.currency!=='INR'||link.notes?.property_id!==job.property_id||link.notes?.reservation_id!==job.reservation_id||link.accept_partial===true||!paymentUrl(link.short_url))throw new PaymentError('Provider payment link does not match this hotel bill.');}
 async function snapshot(link,job){validate(link,job);const clean={id:link.id,reference_id:link.reference_id,amount:link.amount,currency:link.currency,status:link.status,order_id:link.order_id,short_url:link.short_url,notes:{property_id:link.notes.property_id,reservation_id:link.notes.reservation_id}};if(link.status!=='paid')return{link:clean};
  const payments=(link.payments??[]).filter(p=>p.status==='captured');if(payments.length!==1||!/^pay_[A-Za-z0-9]+$/.test(payments[0].payment_id))throw new PaymentError('A single full captured payment must be verified.');
  const p=await api('payments/'+payments[0].payment_id);if(p.id!==payments[0].payment_id||!/^order_[A-Za-z0-9]+$/.test(link.order_id??'')||p.status!=='captured'||p.captured!==true||p.amount!==Number(job.amount)||p.currency!=='INR'||p.order_id!==link.order_id)throw new PaymentError('Captured payment does not match this hotel bill.');
  let refunds=[];if(p.amount_refunded>0){const data=await api('payments/'+p.id+'/refunds');if(!Array.isArray(data.items)||data.items.length>=100)throw new PaymentError('Refund reconciliation needs staff review.');refunds=data.items.map(r=>({id:r.id,payment_id:r.payment_id,amount:r.amount,status:r.status}));}
  return{link:clean,payment:{id:p.id,amount:p.amount,currency:p.currency,status:p.status,captured:p.captured,order_id:p.order_id,method:p.method},refunds};
 }
 return{verify:()=>api('payment_links?count=1'),async process(job){
  let link=await find(job);
  if(!link&&job.operation==='cancel'&&!job.creation_started)return{link:null,cancelled:true};
  if(!link&&!job.creation_started&&Date.parse(job.expires_at)<=Date.now())return{link:null,expired:true};
  if(!link&&job.operation==='create')link=await api('payment_links','POST',{amount:Number(job.amount),currency:'INR',accept_partial:false,reference_id:reference(job.id),description:'Hotel checkout · '+job.reservation_id.slice(0,8).toUpperCase(),expire_by:Math.floor(Date.parse(job.expires_at)/1000),notify:{sms:false,email:false},reminder_enable:false,notes:{property_id:job.property_id,reservation_id:job.reservation_id}});
  if(!link)return{link:null};validate(link,job);
  if(job.operation==='cancel'&&link.status==='created')link=await api('payment_links/'+link.id+'/cancel','POST',{});
  return snapshot(link,job);
 }};
}

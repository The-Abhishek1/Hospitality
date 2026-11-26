export function signupEvent(origin,value){
 if(!['https://www.facebook.com','https://web.facebook.com','https://business.facebook.com'].includes(origin))return null;
 try{const d=typeof value==='string'?JSON.parse(value):value;
 if(d?.type!=='WA_EMBEDDED_SIGNUP'||!['FINISH','FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING'].includes(d.event))return null;
 const {phone_number_id:phone,waba_id:waba}=d.data??{};
 if(d.event==='FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING')return /^\d{5,30}$/.test(waba??'')&&(!phone||/^\d{5,30}$/.test(phone))?{waba,...(phone?{phone}:{}),coexistence:true}:null;
 return /^\d{5,30}$/.test(phone??'')&&/^\d{5,30}$/.test(waba??'')?{phone,waba}:null;
 }catch{return null;}
}
export function signupFailure(origin,value){
 if(!['https://www.facebook.com','https://web.facebook.com','https://business.facebook.com'].includes(origin))return null;
 try{
  const d=typeof value==='string'?JSON.parse(value):value;
  if(d?.type!=='WA_EMBEDDED_SIGNUP')return null;
  if(d.event==='CANCEL')return 'Meta setup was cancelled. Your saved connection was not changed.';
  if(d.event!=='ERROR')return null;
  const code=String(d.data?.error_code??d.data?.error_id??d.error?.code??'');
  if(code==='3441107')return 'Meta has not enabled this app to connect WhatsApp Business app numbers. Complete Tech Provider approval and the required Advanced Access in Meta before retrying.';
  return 'Meta could not complete the connection. Check the app’s Coexistence eligibility and the business account status in Meta. Your saved connection was not changed.';
 }catch{return null;}
}

export function signupEvent(origin,value){
 if(!['https://www.facebook.com','https://web.facebook.com','https://business.facebook.com'].includes(origin))return null;
 try{const d=typeof value==='string'?JSON.parse(value):value;
 if(d?.type!=='WA_EMBEDDED_SIGNUP'||d.event!=='FINISH')return null;
 const {phone_number_id:phone,waba_id:waba}=d.data??{};
 return /^\d{5,30}$/.test(phone??'')&&/^\d{5,30}$/.test(waba??'')?{phone,waba}:null;
 }catch{return null;}
}

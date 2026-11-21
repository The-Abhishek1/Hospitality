import {createCipheriv,createDecipheriv,randomBytes} from 'node:crypto';
function key(value){if(!/^[a-f0-9]{64}$/i.test(value??''))throw Error('WhatsApp encryption key is not configured');return Buffer.from(value,'hex');}
export function encryptToken(token,reference,secret){
 const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key(secret),iv);cipher.setAAD(Buffer.from(reference));
 const data=Buffer.concat([cipher.update(token,'utf8'),cipher.final()]);
 return ['v1',iv.toString('base64url'),cipher.getAuthTag().toString('base64url'),data.toString('base64url')].join('.');
}
export function decryptToken(value,reference,secret){
 const [version,iv,tag,data,...rest]=value.split('.');if(version!=='v1'||!iv||!tag||!data||rest.length)throw Error('Invalid encrypted credential');
 const cipher=createDecipheriv('aes-256-gcm',key(secret),Buffer.from(iv,'base64url'));cipher.setAAD(Buffer.from(reference));cipher.setAuthTag(Buffer.from(tag,'base64url'));
 return Buffer.concat([cipher.update(Buffer.from(data,'base64url')),cipher.final()]).toString('utf8');
}

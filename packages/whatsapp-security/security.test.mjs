import {test}from'node:test';import assert from'node:assert/strict';
import{encryptToken,decryptToken}from'./index.mjs';
import{signupEvent}from'./signup-event.mjs';
test('credentials are authenticated and bound to the hotel reference',()=>{
 const key='ab'.repeat(32),value=encryptToken('private-token','managed:hotel-a',key);
 assert.equal(decryptToken(value,'managed:hotel-a',key),'private-token');
 assert.throws(()=>decryptToken(value,'managed:hotel-b',key));
 assert.throws(()=>decryptToken(value,'managed:hotel-a','cd'.repeat(32)));
 assert.throws(()=>decryptToken(value.slice(0,-3)+'abc','managed:hotel-a',key));
 assert.throws(()=>encryptToken('token','hotel',undefined));
});
test('signup accepts only exact Meta origins and complete Cloud API sessions',()=>{
 const value={type:'WA_EMBEDDED_SIGNUP',event:'FINISH',data:{phone_number_id:'123456',waba_id:'234567'}};
 assert.deepEqual(signupEvent('https://www.facebook.com',JSON.stringify(value)),{phone:'123456',waba:'234567'});
 for(const origin of ['https://evilfacebook.com','https://www.facebook.com.evil.test','http://www.facebook.com','null'])assert.equal(signupEvent(origin,value),null);
 assert.equal(signupEvent('https://www.facebook.com',{...value,event:'CANCEL'}),null);
 assert.equal(signupEvent('https://www.facebook.com',{...value,data:{}}),null);
});

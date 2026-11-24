import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
const source=readFileSync(new URL('../src/lib/team-email.ts',import.meta.url),'utf8').replace("import 'server-only';",''),code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {teamEmailConfig,teamEmailStatus,invitationEmail,sendInvitationEmail}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const env={RESEND_API_KEY:'re_test_not_live',TEAM_EMAIL_FROM:'Hospitality <admin@example.test>',APP_URL:'https://hotel.example.test',NEXT_PUBLIC_SUPABASE_URL:'https://backend.example.test',SUPABASE_SERVICE_ROLE_KEY:'not-a-real-service-key',NODE_ENV:'production'},config=teamEmailConfig(env),context={email:'staff@example.test',business:'Hotel & team <script>alert(1)</script>',business_role:'member',expires_at:'2026-12-24T12:00:00Z',hotels:[{name:'Beach <hotel>',roles:['Front desk & reception']}]};
test('email configuration requires private key, backend result credentials and trusted app origin',()=>{
 assert.equal(config.origin,'https://hotel.example.test');
 for(const override of[{RESEND_API_KEY:undefined},{RESEND_API_KEY:'wrong'},{SUPABASE_SERVICE_ROLE_KEY:undefined},{APP_URL:'http://evil.example'},{APP_URL:'https://user:pass@example.test'},{APP_URL:''},{TEAM_EMAIL_FROM:'admin@example.test\r\nBcc: victim@example.test'},{TEAM_EMAIL_FROM:'invalid'}])assert.equal(teamEmailConfig({...env,...override}),null);
 assert.equal(teamEmailConfig({...env,APP_URL:'http://localhost:3120',NODE_ENV:'development'}).origin,'http://localhost:3120');
 assert.equal(teamEmailConfig({...env,APP_URL:'http://localhost:3120'}),null);
});
test('invitation safely escapes names and contains real login/signup links, reviewed roles and exact email',()=>{
 const mail=invitationEmail(context,config);assert.deepEqual(mail.to,['staff@example.test']);assert.equal(mail.from,env.TEAM_EMAIL_FROM);assert.ok(!mail.html.includes('<script>'));assert.ok(mail.html.includes('&lt;hotel&gt;'));assert.ok(mail.html.includes('https://hotel.example.test/login'));assert.ok(mail.html.includes('https://hotel.example.test/signup'));assert.ok(mail.text.includes('Front desk & reception'));assert.ok(mail.text.includes('staff@example.test'));assert.ok(mail.text.includes('UTC'));assert.ok(mail.text.includes('confirmed email'));assert.ok(!mail.html.includes('re_test'));
});
test('business administrator invitation describes full business access',()=>{
 const mail=invitationEmail({...context,business_role:'admin',hotels:[]},config);assert.ok(mail.text.includes('all current and future hotels'));assert.ok(!mail.text.includes('Beach'));
});
test('provider acceptance sends to exactly one invited address with a stable idempotency key',async()=>{
 let call;const result=await sendInvitationEmail(context,'delivery-id-1',config,async(url,options)=>{call={url,...options};return new Response(JSON.stringify({id:'provider-id-1'}),{status:200});});assert.deepEqual(result,{status:'sent',providerId:'provider-id-1'});assert.equal(call.url,'https://api.resend.com/emails');assert.equal(call.headers['Idempotency-Key'],'team-invitation/delivery-id-1');assert.deepEqual(JSON.parse(call.body).to,[context.email]);assert.equal(call.headers.Authorization,'Bearer re_test_not_live');assert.equal(call.cache,'no-store');
});
test('definite provider rejections expose safe errors without raw provider content or credentials',async()=>{
 for(const[status,error]of[[401,'authorization'],[403,'sender'],[422,'provider'],[429,'rate_limit']]){const result=await sendInvitationEmail(context,'id',config,async()=>new Response('sensitive raw provider diagnostic',{status}));assert.deepEqual(result,{status:'failed',error});assert.ok(!JSON.stringify(result).includes('sensitive'));}
});
test('server errors, timeouts and ambiguous responses never claim delivery or retry automatically',async()=>{
 for(const fetcher of[async()=>new Response('{}',{status:503}),async()=>new Response('{}',{status:409}),async()=>{throw Error('timeout secret');},async()=>new Response('{}',{status:200}),async()=>new Response('invalid JSON',{status:200})]){let calls=0;const result=await sendInvitationEmail(context,'id',config,async(...args)=>{calls++;return fetcher(...args);});assert.deepEqual(result,{status:'unknown',error:'uncertain'});assert.equal(calls,1);}
});

test('platform email diagnostics report only setting names, never secret values',()=>{
 assert.deepEqual(teamEmailStatus(env),{configured:true,issues:[]});const status=teamEmailStatus({...env,RESEND_API_KEY:undefined,APP_URL:'invalid',SUPABASE_SERVICE_ROLE_KEY:undefined});assert.deepEqual(status.issues,['RESEND_API_KEY','APP_URL','SUPABASE_SERVICE_ROLE_KEY']);assert.ok(!JSON.stringify(status).includes('re_test'));assert.ok(!JSON.stringify(status).includes(env.TEAM_EMAIL_FROM));
});

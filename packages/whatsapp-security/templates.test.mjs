import{test}from'node:test';import assert from'node:assert/strict';import{normalizeTemplate,fetchTemplates}from'./templates.mjs';
const template={id:'1',name:'stay_update',language:'en_US',category:'UTILITY',status:'APPROVED',components:[{type:'BODY',text:'Hello {{1}} from {{2}}. {{1}}'}]};
test('parameter ordering and unsupported provider components',()=>{
 assert.deepEqual(normalizeTemplate(template).parameter_names,['1','2']);assert.equal(normalizeTemplate(template).supported,true);
 for(const extra of [{type:'HEADER',format:'IMAGE'},{type:'BUTTONS',buttons:[]}])assert.equal(normalizeTemplate({...template,components:[...template.components,extra]}).supported,false);
 for(const body of ['Hello {{2}}','Hello {{1}} {{guest}}','Hello {{0}}','Hello {{broken'])assert.equal(normalizeTemplate({...template,components:[{type:'BODY',text:body}]}).supported,false);
 assert.deepEqual(normalizeTemplate({...template,components:[{type:'BODY',text:'Hello {{guest_name}} from {{hotel_name}}'}]}).parameter_names,['guest_name','hotel_name']);
});
test('sync completes all pages before returning and never accepts a partial directory',async()=>{
 let page=0;const fetcher=async(url,options)=>{assert.match(options.headers.Authorization,/Bearer/);page++;return new Response(JSON.stringify(page===1?{data:[template],paging:{next:'do-not-follow-arbitrary-url',cursors:{after:'cursor'}}}:{data:[]}));};
 assert.equal((await fetchTemplates('123','secret','v27.0',fetcher)).length,1);assert.equal(page,2);
 await assert.rejects(()=>fetchTemplates('123','secret','v27.0',async()=>new Response(JSON.stringify({data:[template],paging:{next:'bad'}}))));
 await assert.rejects(()=>fetchTemplates('123','secret','v27.0',async()=>new Response(JSON.stringify({error:{code:190}}),{status:400})));
});

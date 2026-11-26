import{test}from'node:test';import assert from'node:assert/strict';import{readFileSync}from'node:fs';import ts from'typescript';
import{readSheet}from'read-excel-file/node';
const code=ts.transpileModule(readFileSync(new URL('../src/lib/menu-import.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const{parseMenuCsv,buildMenuImport,menuImportColumns}=await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const header=['name','category','price','food_type','served_in','size','available'];
test('downloadable Excel and CSV templates both produce the same three items and sizes',async()=>{
 const csv=buildMenuImport(parseMenuCsv(readFileSync(new URL('../public/templates/food-menu-import.csv',import.meta.url),'utf8'))),xlsx=buildMenuImport(await readSheet(new URL('../public/templates/food-menu-import.xlsx',import.meta.url).pathname));
 assert.deepEqual(csv.issues,[]);assert.deepEqual(xlsx.issues,[]);assert.deepEqual(csv.items,xlsx.items);assert.equal(csv.items.length,3);assert.equal(csv.items[0].details.variants.length,2);assert.equal(csv.items[0].details.active,false);assert.deepEqual(parseMenuCsv(readFileSync(new URL('../public/templates/food-menu-import.csv',import.meta.url),'utf8'))[0],menuImportColumns);
});
test('quoted CSV handles commas, escaped quotes, UTF-8, multiline descriptions and CRLF',()=>{
 const rows=parseMenuCsv('\uFEFFname,category,price,description\r\n"Café, special",Drinks,100,"Fresh ""local"" coffee\nwith milk"\r\n');
 assert.equal(rows[1][0],'Café, special');assert.equal(rows[1][3],'Fresh "local" coffee\nwith milk');assert.deepEqual(buildMenuImport(rows).issues,[]);
});
test('semicolon CSV and a 30-dish spreadsheet import without individual item entry',()=>{
 assert.deepEqual(buildMenuImport(parseMenuCsv('name;category;price\nTea;Drinks;50')).issues,[]);
 const plan=buildMenuImport([header,...Array.from({length:30},(_,i)=>['Dish '+i,'Mains',100,'veg','both','','TRUE'])]);assert.equal(plan.items.length,30);assert.deepEqual(plan.issues,[]);assert.equal(plan.items[0].details.active,true);
});
test('missing, repeated and unknown headings report a template error',()=>{
 for(const rows of[[['name','price'],['Tea',50]],[['name','category','price','name'],['Tea','Drinks',50,'Tea']],[['name','category','price','image_url'],['Tea','Drinks',50,'https://example.test/p.jpg']]])assert.ok(buildMenuImport(rows).issues.some(e=>e.row===1));
});
test('invalid prices, tax, destinations and preparation times identify their source row',()=>{
 const rows=[['name','category','price','tax_percent','food_type','served_in','prep_minutes'],['Tea','Drinks','-50','101','made_up','kitchen','300']];
 const plan=buildMenuImport(rows);assert.ok(plan.issues.length>=5);assert.ok(plan.issues.every(e=>e.row===2));
 for(const value of['₹100','1,000','=SUM(A1)','1e5','3.141'])assert.ok(buildMenuImport([header,['Tea','Drinks',value]]).issues.length);
});
test('sizes must have unique labels and matching item metadata',()=>{
 const row=['Curry','Mains',100,'veg','both','Half','FALSE'];
 for(const second of[[...row],[...row.slice(0,3),'non_veg','both','Full','FALSE'],['Curry','Mains',100,'veg','both','','FALSE']])assert.ok(buildMenuImport([header,row,second]).issues.length);
 const valid=buildMenuImport([header,row,['Curry','Mains',180,'veg','both','Full','FALSE']]);assert.deepEqual(valid.issues,[]);assert.equal(valid.items.length,1);assert.equal(valid.items[0].details.pricing_mode,'sizes');
});
test('blank values do not invent dietary claims or publish dishes',()=>{const plan=buildMenuImport([['name','category','price'],['Tea','Drinks',50]]);assert.equal(plan.items[0].details.dietary_type,'not_specified');assert.equal(plan.items[0].details.service_scope,'both');assert.equal(plan.items[0].details.active,false);});
test('broken CSV and oversized files are rejected before import',()=>{assert.throws(()=>parseMenuCsv('name,category,price\n"Tea,Drinks,50'),/not closed/);assert.throws(()=>parseMenuCsv('name,category,price\n'+Array.from({length:501},()=> 'Tea,Drinks,50').join('\n')),/500/);assert.ok(buildMenuImport([header,...Array.from({length:201},(_,i)=>['Dish '+i,'Mains',50])]).issues.length);});

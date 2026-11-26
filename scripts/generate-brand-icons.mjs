// Run from the repository root: node scripts/generate-brand-icons.mjs
// All sizes are generated from the same font-independent vector mark.
import {createRequire} from 'node:module';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
const require=createRequire(new URL('../apps/web/package.json',import.meta.url));
const sharp=require('sharp');
const root=new URL('../',import.meta.url);
const source=await readFile(new URL('apps/web/public/brand/hospitality-mark.svg',root));
const png=size=>sharp(source,{density:288}).resize(size,size).png().toBuffer();
const assets=await Promise.all([16,32,48].map(png));
const header=Buffer.alloc(6+assets.length*16);header.writeUInt16LE(1,2);header.writeUInt16LE(assets.length,4);
let offset=header.length;
assets.forEach((data,i)=>{const at=6+i*16;header[at]=[16,32,48][i];header[at+1]=[16,32,48][i];header.writeUInt16LE(1,at+4);header.writeUInt16LE(32,at+6);header.writeUInt32LE(data.length,at+8);header.writeUInt32LE(offset,at+12);offset+=data.length;});
const ico=Buffer.concat([header,...assets]);
for(const app of ['web','guest-portal']){
  const base=new URL(`apps/${app}/public/`,root);
  await mkdir(new URL('brand/',base),{recursive:true});await mkdir(new URL('icons/',base),{recursive:true});
  await writeFile(new URL('favicon.svg',base),source);
  await writeFile(new URL('favicon.ico',base),ico);
  await writeFile(new URL('apple-touch-icon.png',base),await png(180));
  await writeFile(new URL('brand/hospitality-app-icon-1024.png',base),await png(1024));
  await writeFile(new URL('brand/hospitality-mark.svg',base),source);
  for(const size of [192,512])await writeFile(new URL(`icons/hospitality-${size}.png`,base),await png(size));
  if(app==='guest-portal')for(const size of [180,192,512])await writeFile(new URL(`icons/stay-${size}.png`,base),await png(size));
  console.log(`Generated ${app} icons in ${fileURLToPath(base)}`);
}

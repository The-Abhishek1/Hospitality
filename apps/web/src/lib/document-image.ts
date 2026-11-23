import sharp from'sharp';
export const maxDocumentPixels=24_000_000;
export class InvalidDocumentPhoto extends Error{}
export async function rebuildDocumentPhoto(input:Uint8Array){
 const jpeg=input[0]===255&&input[1]===216&&input[2]===255,png=[137,80,78,71,13,10,26,10].every((n,i)=>input[i]===n);
 if(input.length<12||input.length>10485760||!jpeg&&!png)throw new InvalidDocumentPhoto('Use a JPG or PNG photo up to 10 MB. PDF and other file types are disabled.');
 try{
  const image=sharp(input,{failOn:'warning',limitInputPixels:maxDocumentPixels,sequentialRead:true,animated:false}),meta=await image.metadata();
  if(!['jpeg','png'].includes(meta.format??'')||!meta.width||!meta.height||(meta.pages??1)>1||meta.width*meta.height>maxDocumentPixels)throw Error();
  // Decode actual pixels and write a fresh, bounded JPEG. No input metadata is copied.
  const{data,info}=await image.rotate().flatten({background:'#ffffff'}).resize({width:3000,height:3000,fit:'inside',withoutEnlargement:true}).jpeg({quality:90}).timeout({seconds:15}).toBuffer({resolveWithObject:true});
  if(!data.length||data.length>10485760||!info.width||!info.height)throw Error();return{data,width:info.width,height:info.height};
 }catch{throw new InvalidDocumentPhoto('This photo could not be read. Upload a clear, single JPG or PNG image up to 24 megapixels.');}
}

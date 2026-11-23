import{backend,meta,graphVersion,SetupError}from'./whatsapp-onboarding';
export async function uploadTemplateSample(pid:string,url:string,token:string){
 const prefix=process.env.NEXT_PUBLIC_SUPABASE_URL+'/storage/v1/object/public/hotel-whatsapp-photos/'+pid+'/';
 if(!url.startsWith(prefix)||!new RegExp('^[a-f0-9-]+\\.(jpg|png)$').test(url.slice(prefix.length)))throw new SetupError('Upload a JPEG or PNG sample using this hotel’s photo uploader.');
 const path=pid+'/'+url.slice(prefix.length),r=await backend().storage.from('hotel-whatsapp-photos').download(path);if(r.error||!r.data||r.data.size>4*1024*1024)throw new SetupError('Sample image unavailable. Upload the hotel photo again.');
 const session=await meta(`${process.env.WHATSAPP_APP_ID}/uploads`,token,'POST',{file_name:url.endsWith('.png')?'sample.png':'sample.jpg',file_length:String(r.data.size),file_type:url.endsWith('.png')?'image/png':'image/jpeg'},'template');
 if(typeof session.id!=='string'||!session.id.startsWith('upload:'))throw new SetupError('Meta could not start the sample upload.');
 const response=await fetch(`https://graph.facebook.com/${graphVersion}/${session.id}`,{method:'POST',headers:{Authorization:`OAuth ${token}`,file_offset:'0'},body:await r.data.arrayBuffer(),signal:AbortSignal.timeout(30000)}),d=await response.json();if(!response.ok||typeof d.h!=='string')throw new SetupError('Meta rejected the sample image upload. Check account permissions and use a JPEG or PNG.');return d.h as string;
}

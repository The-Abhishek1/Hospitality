export type HotelLinks={maps_url:string;review_url:string;website_url:string};
export type HotelPhoto={id:string;name:string;url:string;mime_type:string|null};
export type HotelResources={version:number;links:HotelLinks;photos:HotelPhoto[]};
export const emptyHotelLinks:HotelLinks={maps_url:'',review_url:'',website_url:''};
export const hotelLinkChoices=[{key:'maps_url',label:'Hotel location',button:'Get directions'},{key:'review_url',label:'Review link',button:'Leave a review'},{key:'website_url',label:'Hotel website',button:'Visit website'}]as const;
export function hotelLinkButton(links:HotelLinks,key:string){const item=hotelLinkChoices.find(i=>i.key===key);return item&&links[item.key]?{text:item.button,url:links[item.key]}:null;}
export function templatePhotoReady(photo:HotelPhoto,pid:string,origin:string){const prefix=origin.replace(/\/$/,'')+'/storage/v1/object/public/hotel-whatsapp-photos/'+pid+'/';return photo.url.startsWith(prefix)&&/^[a-f0-9-]+\.(jpg|png)$/.test(photo.url.slice(prefix.length))&&['image/jpeg','image/png'].includes(photo.mime_type??'');}

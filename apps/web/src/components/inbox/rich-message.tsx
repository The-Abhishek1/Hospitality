type RichPayload={type?:string;template?:{components?:{type:string;parameters?:{image?:{link?:string}}[]}[]};image?:{link?:string};interactive?:{type?:string;header?:{type?:string;image?:{link?:string}};action?:{parameters?:{url?:string;display_text?:string};sections?:{rows?:{id:string;title:string}[]}[]}}};
export function RichMessage({payload}:{payload:RichPayload|null|undefined}){
 if(!payload)return null;
 const templatePhoto=payload.template?.components?.find(c=>c.type==='header')?.parameters?.[0]?.image?.link??payload.interactive?.header?.image?.link;
 const image=payload.image?.link;
 const link=payload.interactive?.action?.parameters;
 return <>{templatePhoto?.startsWith('https://')&&<a href={templatePhoto} target="_blank" rel="noopener noreferrer"><img className="ib-hotel-photo" src={templatePhoto} alt="Hotel photo" loading="lazy" referrerPolicy="no-referrer"/></a>}{payload.type==='image'&&image&&(image.startsWith('https://')||/^\/api\/whatsapp\/[a-f0-9-]{36}\/inbox\/photos\/[a-f0-9-]{36}$/.test(image))&&<a href={image} target="_blank" rel="noopener noreferrer"><img className="ib-hotel-photo" src={image} alt="Photo shared by the hotel" loading="lazy" referrerPolicy="no-referrer"/></a>}{payload.interactive?.type==='list'&&<ol className="ib-menu-preview">{payload.interactive.action?.sections?.flatMap(s=>s.rows??[]).map(r=><li key={r.id}>{r.title}</li>)}</ol>}{link?.url?.startsWith('https://')&&<a className="ib-guest-link" href={link.url} target="_blank" rel="noopener noreferrer">{link.display_text??'Open link'} ↗</a>}</>;
}

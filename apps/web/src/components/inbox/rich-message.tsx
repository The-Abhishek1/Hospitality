type RichPayload={type?:string;image?:{link?:string};interactive?:{type?:string;action?:{parameters?:{url?:string;display_text?:string};sections?:{rows?:{id:string;title:string}[]}[]}}};
export function RichMessage({payload}:{payload:RichPayload|null|undefined}){
 if(!payload)return null;
 const link=payload.interactive?.action?.parameters;
 return <>{payload.type==='image'&&payload.image?.link?.startsWith('https://')&&<a href={payload.image.link} target="_blank" rel="noopener noreferrer"><img className="ib-hotel-photo" src={payload.image.link} alt="Photo shared by the hotel" loading="lazy" referrerPolicy="no-referrer"/></a>}{payload.interactive?.type==='list'&&<ol className="ib-menu-preview">{payload.interactive.action?.sections?.flatMap(s=>s.rows??[]).map(r=><li key={r.id}>{r.title}</li>)}</ol>}{link?.url?.startsWith('https://')&&<a className="ib-guest-link" href={link.url} target="_blank" rel="noopener noreferrer">{link.display_text??'Open link'} ↗</a>}</>;
}

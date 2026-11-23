import{createTemplatePayload}from'./automation-flow';
export type TemplateExtras={header_kind?:'none'|'text'|'image';header_text?:string;image_url?:string;footer?:string;buttons?:{text:string;url:string}[];category?:'UTILITY'|'MARKETING'};
export function richTemplatePayload(input:Parameters<typeof createTemplatePayload>[0]&TemplateExtras){
 const base=createTemplatePayload(input),components:Record<string,unknown>[]=[...base.components];
 if(input.header_kind==='text'){if(!input.header_text?.trim()||input.header_text.length>60||/[{}]/.test(input.header_text))throw Error('Use a static header of 1–60 characters.');components.unshift({type:'HEADER',format:'TEXT',text:input.header_text.trim()});}
 else if(input.header_kind==='image'){if(!input.image_url?.startsWith('https://'))throw Error('Upload a sample hotel image for the header.');components.unshift({type:'HEADER',format:'IMAGE'});}
 else if(input.header_kind&&input.header_kind!=='none')throw Error('Choose a supported header type.');
 if(input.footer){if(input.footer.length>60||/[{}]/.test(input.footer))throw Error('Use a static footer up to 60 characters.');components.push({type:'FOOTER',text:input.footer});}
 if(input.buttons!==undefined){if(!Array.isArray(input.buttons)||input.buttons.length>2)throw Error('Add up to two link buttons.');for(const b of input.buttons){let u;try{u=new URL(b.url);}catch{throw Error('Use a valid HTTPS link for each button.');}if(!b.text?.trim()||b.text.length>20||u.protocol!=='https:'||u.username||u.password||/\/s\//.test(u.pathname)||u.searchParams.has('access_token')||u.searchParams.has('token')||/[{}]/.test(b.url))throw Error('Use button labels up to 20 characters and static HTTPS links. Personal guest links belong in the body as {{portal_url}}.');}if(input.buttons.length)components.push({type:'BUTTONS',buttons:input.buttons.map(b=>({type:'URL',text:b.text,url:b.url}))});}
 return{...base,category:input.event==='service_reply'?(input.category==='MARKETING'?'MARKETING':'UTILITY'):base.category,components};
}

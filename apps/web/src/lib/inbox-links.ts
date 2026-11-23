// Display friendly links without changing the message body stored or sent to WhatsApp.
const guestTaskLabels:Record<string,string>={documents:'Upload documents',arrival:'Upload documents',food:'Order food',bill:'View bill',services:'Guest services'};
export type MessagePart={text:string;href?:string};
export function inboxMessageParts(body:string):MessagePart[]{
 const parts:MessagePart[]=[];let cursor=0;
 for(const match of body.matchAll(/https?:\/\/[^\s<>]+/g)){
  const start=match.index!,raw=match[0],href=raw.replace(/[.,!;:]+$/,'').replace(/\)+$/,tail=>{
   const opens=(raw.match(/\(/g)??[]).length,closes=(raw.match(/\)/g)??[]).length;return tail.slice(0,Math.max(0,tail.length-Math.max(0,closes-opens)));
  });
  if(start>cursor)parts.push({text:body.slice(cursor,start)});
  try{const url=new URL(href),guest=/^\/s\/[^/]+(?:\/|$)/.test(url.pathname),task=url.pathname.split('/')[3]||url.searchParams.get('view');
   const text=guest?(guestTaskLabels[task??'']??'Open guest page')+` · ${url.hostname}`:url.hostname.replace(/^www\./,'')+(url.pathname==='/'?'':url.pathname.length>32?url.pathname.slice(0,29)+'…':url.pathname);
   parts.push({text,href});
  }catch{parts.push({text:href});}
  cursor=start+href.length;
 }
 if(cursor<body.length)parts.push({text:body.slice(cursor)});
 return parts;
}

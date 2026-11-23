import{inboxMessageParts}from'@/lib/inbox-links';
export function MessageText({body}:{body:string}){return <p>{inboxMessageParts(body).map((part,index)=>part.href?<a key={index} href={part.href} target="_blank" rel="noopener noreferrer">{part.text} ↗</a>:<span key={index}>{part.text}</span>)}</p>;}

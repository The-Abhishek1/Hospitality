'use client';
import{useEffect,useId,useRef,useState}from'react';
export function ChatDetails({children}:{children:React.ReactNode}){
 const[open,setOpen]=useState(false),root=useRef<HTMLDivElement>(null),trigger=useRef<HTMLButtonElement>(null),id=useId();
 useEffect(()=>{if(!open)return;const outside=(e:PointerEvent)=>{if(!root.current?.contains(e.target as Node))setOpen(false);},escape=(e:KeyboardEvent)=>{if(e.key==='Escape'){setOpen(false);trigger.current?.focus();}};document.addEventListener('pointerdown',outside);document.addEventListener('keydown',escape);return()=>{document.removeEventListener('pointerdown',outside);document.removeEventListener('keydown',escape);};},[open]);
 return <div className="ib-chat-details" ref={root}><button ref={trigger} className="ib-details-trigger" type="button" aria-label="Chat details" aria-expanded={open} aria-controls={id} onClick={()=>setOpen(!open)}>Chat details <span aria-hidden="true">ⓘ</span></button>{open&&<aside className="ib-details-panel" id={id} aria-label="Conversation details"><div className="ib-details-heading"><h3>Chat details</h3><button type="button" aria-label="Close conversation details" onClick={()=>{setOpen(false);trigger.current?.focus();}}>×</button></div>{children}</aside>}</div>;
}

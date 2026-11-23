import {Children,Fragment,cloneElement,isValidElement,type ComponentProps,type ReactNode} from 'react';
type NodeProps={children?:ReactNode;colSpan?:number};
function nodes(children:ReactNode):ReactNode[]{return Children.toArray(children).flatMap(child=>isValidElement<NodeProps>(child)&&child.type===Fragment?nodes(child.props.children):[child]);}
function text(node:ReactNode):string{return nodes(node).map(n=>typeof n==='string'||typeof n==='number'?String(n):isValidElement<NodeProps>(n)?text(n.props.children):'').join(' ').trim();}
/** Preserve the table on desktop and supply visible field labels for mobile cards. */
export function DataTable({children,className='',...props}:ComponentProps<'table'>){
 const sections=nodes(children),head=sections.find(n=>isValidElement(n)&&n.type==='thead'),row=isValidElement<NodeProps>(head)?nodes(head.props.children).find(n=>isValidElement(n)&&n.type==='tr'):null,labels=isValidElement<NodeProps>(row)?nodes(row.props.children).flatMap(n=>isValidElement<NodeProps>(n)?Array.from({length:n.props.colSpan??1},()=>text(n.props.children)):['']):[];
 return <table {...props} className={`${className} simple-data-table`}>{sections.map(section=>{
  if(!isValidElement<NodeProps>(section)||section.type!=='tbody')return section;
  return cloneElement(section,{},nodes(section.props.children).map(r=>{
   if(!isValidElement<NodeProps>(r)||r.type!=='tr')return r;
   return cloneElement(r,{},nodes(r.props.children).map((cell,i)=>isValidElement<NodeProps>(cell)&&cell.type==='td'?cloneElement(cell,{'data-label':labels[i]||'Details'} as ComponentProps<'td'>):cell));
  }));
 })}</table>;
}

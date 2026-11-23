import {Children,Fragment,cloneElement,isValidElement,type ComponentProps,type ReactNode} from 'react';

type Field={className?:string;type?:string;children?:ReactNode};
function nodes(children:ReactNode):ReactNode[]{return Children.toArray(children).flatMap(child=>isValidElement<Field>(child)&&child.type===Fragment?nodes(child.props.children):[child]);}
/** Keep search visible while optional GET fields remain submitted inside closed details. */
export function QueueFilters({children,active=0,className='',...props}:ComponentProps<'form'>&{active?:number}){
 const items=nodes(children),labels=items.filter(n=>isValidElement(n)&&n.type==='label'),search=labels.find(n=>isValidElement<Field>(n)&&/search/.test(n.props.className??'')),filters=labels.filter(n=>n!==search),hidden=items.filter(n=>isValidElement<Field>(n)&&n.type==='input'&&n.props.type==='hidden'),actions=items.filter(n=>!labels.includes(n)&&!hidden.includes(n)),submit=actions.find(n=>isValidElement(n)&&n.type==='button');
 return <form {...props} method={props.method??'get'} className={`${className} simple-filter-form`}>
  {hidden}<div className="simple-search-row">{search}{submit&&isValidElement(submit)?cloneElement(submit,{},'Search'):null}{actions.filter(n=>n!==submit)}</div>
  {filters.length>0&&<details className="simple-extra-filters"><summary>Filters {active>0&&<span>{active} active</span>}</summary><div className="simple-filter-fields">{filters}<button className="dash-button dash-secondary" type="submit">Apply filters</button></div></details>}
 </form>;
}

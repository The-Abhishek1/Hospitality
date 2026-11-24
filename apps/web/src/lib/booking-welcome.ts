import {automationStarters, eventFields, templateUsable} from './automation-flow';
import type {TemplateExtras} from './rich-templates';
type WelcomeTemplate = {body:string;language:string;parameters:string[];supported:boolean;status:string;category:string;checked_at:string};
export function welcomeKeys(template:WelcomeTemplate, existing?:string[]) {
 const fields=eventFields('booking_confirmed');
 const keys=existing?.length===template.parameters.length?existing:template.parameters.map(name=>fields.includes(name)?name:'');
 return templateUsable(template,'booking_confirmed')&&keys.every(key=>fields.includes(key))&&keys.includes('portal_url')?keys:null;
}
export type WelcomeDraft={body:string;language:string;extras:TemplateExtras};
export function welcomeDraft(template?:{body:string;language:string;image_url?:string;definition?:{components:{type:string;format?:string;text?:string;buttons?:{type:string;text:string;url:string}[]}[]}}):WelcomeDraft {
 if(!template||/\{\{\s*\d+\s*\}\}/.test(template.body))return{body:automationStarters.booking_confirmed,language:'en_US',extras:{header_kind:'none',buttons:[]}};
 const components=template.definition?.components??[],header=components.find(c=>c.type==='HEADER');
 return {body:template.body,language:template.language,extras:{header_kind:header?.format==='IMAGE'?'image':header?.format==='TEXT'?'text':'none',header_text:header?.text,image_url:template.image_url,footer:components.find(c=>c.type==='FOOTER')?.text,buttons:components.find(c=>c.type==='BUTTONS')?.buttons?.filter(b=>b.type==='URL').map(({text,url})=>({text,url}))??[]}};
}

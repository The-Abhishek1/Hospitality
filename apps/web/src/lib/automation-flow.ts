export const automationFields:Record<string,string>={guest_name:'Guest name',hotel_name:'Hotel name',booking_reference:'Booking reference',check_in:'Arrival date',check_out:'Departure date',hotel_phone:'Hotel phone',room_name:'Room',event_label:'Event description',order_reference:'Order reference',request_title:'Guest request title',amount:'Amount for this event',currency:'Currency',invoice_number:'Invoice number',portal_url:'Personal guest portal link',review_url:'Public review link'};
export const sampleValues:Record<string,string>={guest_name:'Alex',hotel_name:'Seaside Hotel',booking_reference:'DEMO1234',check_in:'1 Dec 2026',check_out:'3 Dec 2026',hotel_phone:'+91 90000 00000',room_name:'Deluxe 101',event_label:'Check-in confirmed',order_reference:'ORDER123',request_title:'Extra towels',amount:'500.00',currency:'INR',invoice_number:'INV-001',portal_url:'https://xcloak-hospitality-guest.vercel.app/s/sample-private-stay-link',review_url:'https://example.com/hotel-review'};
export const automationStarters:Record<string,string>={
 booking_confirmed:'Hello {{guest_name}}, your booking {{booking_reference}} at {{hotel_name}} is confirmed for {{check_in}} to {{check_out}}. Your personal stay page: {{portal_url}}. Contact reception if you need assistance.',
 booking_changed:'Hello {{guest_name}}, your booking {{booking_reference}} at {{hotel_name}} has been updated. Your stay is {{check_in}} to {{check_out}}. Current details: {{portal_url}}. Contact reception if you need assistance.',
 booking_cancelled:'Hello {{guest_name}}, your booking {{booking_reference}} at {{hotel_name}} has been cancelled. Contact reception if you need assistance.',
 checked_in:'Hello {{guest_name}}, your check-in at {{hotel_name}} is confirmed. Your personal stay page and available services: {{portal_url}}. Contact reception if you need assistance.',
 checked_out:'Hello {{guest_name}}, your checkout at {{hotel_name}} is complete. Thank you for staying with us. Contact reception if you need assistance.',
 arrival_reminder:'Hello {{guest_name}}, we look forward to welcoming you to {{hotel_name}} on {{check_in}}. Review your arrival details here: {{portal_url}}. Contact reception if you need assistance.',
 checkout_reminder:'Hello {{guest_name}}, your checkout from {{hotel_name}} is scheduled for {{check_out}}. Review your stay and bill here: {{portal_url}}. Contact reception if you need assistance.',
 review_request:'Hello {{guest_name}}, thank you for staying at {{hotel_name}}. If you would like to share your experience, leave a review here: {{review_url}}. Thank you for sharing your experience.',
 order_placed:'Hello {{guest_name}}, {{hotel_name}} has received your food order {{order_reference}}. You can follow your stay details here: {{portal_url}}. Contact reception if you need assistance.',
 order_preparing:'Hello {{guest_name}}, the kitchen at {{hotel_name}} is preparing your food order {{order_reference}}. Contact reception if you need assistance.',
 order_ready:'Hello {{guest_name}}, your food order {{order_reference}} at {{hotel_name}} is ready. Contact reception if you need assistance.',
 order_served:'Hello {{guest_name}}, your food order {{order_reference}} at {{hotel_name}} has been marked as served. Contact reception if anything needs attention.',
 order_cancelled:'Hello {{guest_name}}, your food order {{order_reference}} at {{hotel_name}} has been cancelled. Contact reception if you need assistance.',
 request_received:'Hello {{guest_name}}, {{hotel_name}} has received your request: {{request_title}}. Your stay page: {{portal_url}}. Contact reception if you need assistance.',
 request_started:'Hello {{guest_name}}, the team at {{hotel_name}} is working on your request: {{request_title}}. We will keep you updated.',
 request_completed:'Hello {{guest_name}}, your request at {{hotel_name}} has been completed: {{request_title}}. Contact reception if you need further assistance.',
 request_cancelled:'Hello {{guest_name}}, your request at {{hotel_name}} has been cancelled: {{request_title}}. Contact reception if you need assistance.',
 payment_received:'Hello {{guest_name}}, {{hotel_name}} has recorded a payment of {{amount}} {{currency}} for booking {{booking_reference}}. Your stay and bill: {{portal_url}}. Contact reception if you need assistance.',
 payment_refunded:'Hello {{guest_name}}, {{hotel_name}} has recorded a refund of {{amount}} {{currency}} for booking {{booking_reference}}. Contact reception for processing details.',
 invoice_issued:'Hello {{guest_name}}, invoice {{invoice_number}} for {{amount}} {{currency}} has been issued by {{hotel_name}}. View your stay and bill here: {{portal_url}}. Contact reception if you need assistance.',
 documents_received:'Hello {{guest_name}}, {{hotel_name}} has received your document upload. Check your personal stay page for the current review status: {{portal_url}}. Contact reception if you need assistance.',
 documents_approved:'Hello {{guest_name}}, your document review at {{hotel_name}} has been approved. View your stay details here: {{portal_url}}. Contact reception if you need assistance.',
 documents_rejected:'Hello {{guest_name}}, your document review at {{hotel_name}} needs attention. Open your stay page or contact reception for assistance: {{portal_url}}. Contact reception if you need assistance.'
};
export function templateVariables(body:string){return [...new Set([...body.matchAll(/\{\{\s*([a-z_][a-z0-9_]*)\s*\}\}/g)].map(m=>m[1]))];}
export function previewAutomation(body:string,keys?:string[],parameters?:string[]){return body.replace(/\{\{\s*([a-z_][a-z0-9_]*|[1-9][0-9]*)\s*\}\}/g,(_whole,name)=>{const mapped=keys&&parameters?keys[parameters.indexOf(name)]:name;return sampleValues[mapped]??`[Choose ${name}]`;});}
const serviceFields=['guest_name','hotel_name','hotel_phone','portal_url','booking_reference','check_in','check_out','room_name','review_url'];
export function eventFields(event:string){if(event==='service_reply')return serviceFields;return Object.keys(automationFields).filter(key=>
 (key!=='order_reference'||event.startsWith('order_'))&&(key!=='request_title'||event.startsWith('request_'))&&(key!=='invoice_number'||event==='invoice_issued')&&(key!=='review_url'||event==='review_request')&&(key!=='portal_url'||event!=='booking_cancelled'));
}
export function createTemplatePayload(input:{event:string;name:string;language:string;body:string}){
 const name=input.name.trim(),body=input.body.trim(),variables=templateVariables(body);
 if(input.event!=='service_reply'&&!Object.hasOwn(automationStarters,input.event))throw Error('Choose a hotel event.');
 if(!/^[a-z][a-z0-9_]{2,127}$/.test(name))throw Error('Use a template name with lowercase letters, numbers and underscores (3–128 characters).');
 if(!['en_US','en_GB','en','hi','ta','te','ml','kn','ar'].includes(input.language))throw Error('Choose a supported template language.');
 if(body.length<10||body.length>1024||variables.length>15||body.replace(/\{\{\s*([a-z_][a-z0-9_]*)\s*\}\}/g,'').includes('{{'))throw Error('Use 10–1024 characters and named variables such as {{guest_name}}.');
 if(/^[^\p{L}\p{N}]*\{\{/u.test(body)||/\}\}[^\p{L}\p{N}]*$/u.test(body))throw Error('Meta requires written text before the first variable and after the last variable. Add a closing sentence after the final field; punctuation alone is not enough.');
 if(input.event==='service_reply'&&variables.some(v=>!serviceFields.includes(v)))throw Error('Guest-menu templates support guest, hotel and stay fields. Payment, invoice and order details require an event-specific template.');
 if(variables.some(v=>!Object.hasOwn(automationFields,v)))throw Error('Use the supported guest and stay variables shown in the editor.');
 if(variables.includes('order_reference')&&!input.event.startsWith('order_')||variables.includes('request_title')&&!input.event.startsWith('request_')||variables.includes('invoice_number')&&input.event!=='invoice_issued'||variables.includes('review_url')&&!['review_request','service_reply'].includes(input.event)||variables.includes('portal_url')&&input.event==='booking_cancelled')throw Error('This template uses a field that is unavailable for the chosen event.');
 return{name,language:input.language,category:input.event==='review_request'?'MARKETING':'UTILITY',...(variables.length?{parameter_format:'NAMED'}:{}),components:[{type:'BODY',text:body,...(variables.length?{example:{body_text_named_params:variables.map(param_name=>({param_name,example:sampleValues[param_name]}))}}:{})}]};
}
export function templateUsable(template:{supported:boolean;status:string;category:string;checked_at:string;parameters?:string[]},event:string,now=Date.now()){
 if(!Object.hasOwn(automationStarters,event))return false;
 const available=eventFields(event);
 return template.supported&&template.status==='APPROVED'&&template.category===(event==='review_request'?'marketing':'utility')&&Number.isFinite(Date.parse(template.checked_at))&&Date.parse(template.checked_at)>=now-24*60*60*1000&&(template.parameters??[]).every(name=>!Object.hasOwn(automationFields,name)||available.includes(name));
}
export function setupNext(input:{connected:boolean;approved:number;rules:number;permissions:number;worker:boolean}){
 if(!input.connected)return'connection';if(!input.approved)return'templates';if(!input.rules)return'rules';if(!input.permissions)return'permissions';if(!input.worker)return'worker';return'test';
}

export function templateProviderError(error:{code?:number;error_subcode?:number;message?:string;error_user_title?:string;error_user_msg?:string},status:number,token:string){
 const code=error.code??status,subcode=error.error_subcode;
 let detail=[error.error_user_title,error.error_user_msg??error.message].filter(v=>typeof v==='string'&&v.trim()).join(': ')||'Meta did not provide a reason.';
 if(token)detail=detail.split(token).join('[redacted]');
 detail=detail.replace(/EA[A-Za-z0-9]{40,}|sb_secret_[A-Za-z0-9_-]+|Bearer\s+\S+/gi,'[redacted]').replace(/[\r\n\t]+/g,' ').slice(0,1000);
 const advice=subcode===2388299?' Add written text before and after variables; a full stop alone does not count.':code===190?' Reconnect this hotel’s WhatsApp account to renew authorization.':[10,200].includes(code)?' Check this hotel’s WhatsApp management permissions in Meta.':' Review the template details and try again.';
 return `Meta rejected the template request (code ${code}${subcode?'/'+subcode:''}): ${detail}${advice}`;
}

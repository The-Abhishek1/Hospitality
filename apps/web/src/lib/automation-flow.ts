export const automationFields:Record<string,string>={check_in_time:'Hotel check-in time',check_out_time:'Hotel checkout time',order_summary:'Ordered dishes and quantities',guest_name:'Guest name',hotel_name:'Hotel name',booking_reference:'Booking reference',check_in:'Arrival date',check_out:'Departure date',hotel_phone:'Hotel phone',room_name:'Room',event_label:'Event description',order_reference:'Order reference',request_title:'Guest request title',amount:'Amount for this event',currency:'Currency',invoice_number:'Invoice number',portal_url:'Personal guest portal link',review_url:'Public review link'};
export const sampleValues:Record<string,string>={check_in_time:'14:00',check_out_time:'11:00',order_summary:'2 × Club sandwich, 1 × Lime soda',guest_name:'Alex',hotel_name:'Seaside Hotel',booking_reference:'DEMO1234',check_in:'1 Dec 2026',check_out:'3 Dec 2026',hotel_phone:'+91 90000 00000',room_name:'Deluxe 101',event_label:'Check-in confirmed',order_reference:'ORDER123',request_title:'Extra towels',amount:'500.00',currency:'INR',invoice_number:'INV-001',portal_url:'https://xcloak-hospitality-guest.vercel.app/s/sample-private-stay-link',review_url:'https://example.com/hotel-review'};
export const automationStarters:Record<string,string>={
 "booking_confirmed": "Hello {{guest_name}}, welcome to {{hotel_name}}! Booking {{booking_reference}} is confirmed for {{check_in}} to {{check_out}}. Check-in opens at {{check_in_time}}. Upload identity documents securely here: {{portal_url}}. Reply Hi to choose your WhatsApp stay-update preferences and get help. Offers are optional.",
 "booking_changed": "Hello {{guest_name}}, your booking {{booking_reference}} at {{hotel_name}} has changed. Arrival: {{check_in}} from {{check_in_time}}. Departure: {{check_out}} by {{check_out_time}}. Room: {{room_name}}. Reply Hi for help.",
 "booking_cancelled": "Hello {{guest_name}}, booking {{booking_reference}} at {{hotel_name}} has been cancelled. Contact reception if you need assistance.",
 "checked_in": "Hello {{guest_name}}, you are checked in at {{hotel_name}}. Room: {{room_name}}. Booking: {{booking_reference}}. Checkout: {{check_out}} by {{check_out_time}}. Send Hi or Hello for food, towels, cleaning, repairs or reception assistance.",
 "checked_out": "Hello {{guest_name}}, checkout for booking {{booking_reference}} at {{hotel_name}} is complete. Thank you for staying with us. We look forward to welcoming you again.",
 "arrival_reminder": "Hello {{guest_name}}, your arrival at {{hotel_name}} is today, {{check_in}}, from {{check_in_time}}. Booking: {{booking_reference}}. Approved identity documents and a ready room are required. Reply CHECK IN to review and confirm check-in here on WhatsApp, or Hi for help.",
 "checkout_reminder": "Hello {{guest_name}}, checkout from {{hotel_name}}, room {{room_name}}, is due {{check_out}} by {{check_out_time}}. Reply CHECKOUT to review your bill and confirm departure here. Reception can help with payment or late checkout.",
 "review_request": "Hello {{guest_name}}, thank you for staying at {{hotel_name}}. If you would like to share your experience, leave a review here: {{review_url}}. Thank you for your feedback.",
 "order_placed": "Hello {{guest_name}}, {{hotel_name}} received order {{order_reference}} for room {{room_name}}: {{order_summary}}. Total: {{amount}} {{currency}}. We will keep you updated as the kitchen prepares it. Send Hi for help.",
 "order_preparing": "Hello {{guest_name}}, the kitchen at {{hotel_name}} is preparing order {{order_reference}}: {{order_summary}}. Delivery room: {{room_name}}. Send reception if you need to speak to the team.",
 "order_ready": "Hello {{guest_name}}, order {{order_reference}} at {{hotel_name}} is ready: {{order_summary}}. Room: {{room_name}}. Contact reception if you need assistance.",
 "order_served": "Hello {{guest_name}}, order {{order_reference}} has been delivered to room {{room_name}} at {{hotel_name}}: {{order_summary}}. Total: {{amount}} {{currency}}. Send Hi if you need anything else.",
 "order_cancelled": "Hello {{guest_name}}, order {{order_reference}} at {{hotel_name}} has been cancelled. Contact reception if you need assistance.",
 "request_received": "Hello {{guest_name}}, {{hotel_name}} received your request: {{request_title}}. Room: {{room_name}}. Our team will keep you updated here. Send reception to add details.",
 "request_started": "Hello {{guest_name}}, the team at {{hotel_name}} is working on your request: {{request_title}}. Room: {{room_name}}. We will confirm completion here.",
 "request_completed": "Hello {{guest_name}}, your request at {{hotel_name}} is complete: {{request_title}}. Room: {{room_name}}. Send Hi if you need further help.",
 "request_cancelled": "Hello {{guest_name}}, your request at {{hotel_name}} was cancelled: {{request_title}}. Contact reception if you need assistance.",
 "payment_received": "Hello {{guest_name}}, {{hotel_name}} received {{amount}} {{currency}} for booking {{booking_reference}}. Reply Hi and choose My bill for your itemized statement. Thank you.",
 "payment_refunded": "Hello {{guest_name}}, {{hotel_name}} recorded a refund of {{amount}} {{currency}} for booking {{booking_reference}}. Contact reception for processing details.",
 "invoice_issued": "Hello {{guest_name}}, {{hotel_name}} issued invoice {{invoice_number}} for {{amount}} {{currency}}, booking {{booking_reference}}. Your secure itemized bill: {{portal_url}}. Contact reception if you have questions.",
 "documents_received": "Hello {{guest_name}}, {{hotel_name}} received your identity documents for booking {{booking_reference}}. They are being checked securely. We will confirm when the required review is complete; check-in remains pending until approval.",
 "documents_approved": "Hello {{guest_name}}, {{hotel_name}} approved your required identity documents. Booking: {{booking_reference}}. Arrival: {{check_in}} from {{check_in_time}}; departure: {{check_out}} by {{check_out_time}}. Reply CHECK IN when you arrive, or Hi for help. Your room must be ready before check-in.",
 "documents_rejected": "Hello {{guest_name}}, {{hotel_name}} needs a replacement identity document for booking {{booking_reference}}. Upload it securely here: {{portal_url}}. Please contact reception for review details; do not send ID numbers into this chat."
};
export function templateVariables(body:string){return [...new Set([...body.matchAll(/\{\{\s*([a-z_][a-z0-9_]*)\s*\}\}/g)].map(m=>m[1]))];}
export function previewAutomation(body:string,keys?:string[],parameters?:string[]){return body.replace(/\{\{\s*([a-z_][a-z0-9_]*|[1-9][0-9]*)\s*\}\}/g,(_whole,name)=>{const mapped=keys&&parameters?keys[parameters.indexOf(name)]:name;return sampleValues[mapped]??`[Choose ${name}]`;});}
const serviceFields=['guest_name','hotel_name','hotel_phone','portal_url','booking_reference','check_in','check_out','room_name','review_url'];
export function eventFields(event:string){if(event==='service_reply')return serviceFields;return Object.keys(automationFields).filter(key=>
 (key!=='order_summary'||event.startsWith('order_'))&&(key!=='order_reference'||event.startsWith('order_'))&&(key!=='request_title'||event.startsWith('request_'))&&(key!=='invoice_number'||event==='invoice_issued')&&(key!=='review_url'||event==='review_request')&&(key!=='portal_url'||event!=='booking_cancelled'));
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
 if(variables.includes('order_summary')&&!input.event.startsWith('order_')||variables.includes('order_reference')&&!input.event.startsWith('order_')||variables.includes('request_title')&&!input.event.startsWith('request_')||variables.includes('invoice_number')&&input.event!=='invoice_issued'||variables.includes('review_url')&&!['review_request','service_reply'].includes(input.event)||variables.includes('portal_url')&&input.event==='booking_cancelled')throw Error('This template uses a field that is unavailable for the chosen event.');
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

const metaSampleNames=new Set(['hello_world','jaspers_market_image_cta_v1','jaspers_market_media_carousel_v1','jaspers_market_order_confirmation_v1','jaspers_market_plain_text_v1']);
export function isMetaSampleTemplate(name:string){return metaSampleNames.has(name);}

// One versioned starter pack per hotel; provider approval remains authoritative.
export const eventBodies={
  "booking_confirmed": "Hello {{guest_name}}, welcome to {{hotel_name}}! Booking {{booking_reference}} is confirmed for {{check_in}} to {{check_out}}. Check-in opens at {{check_in_time}}. Upload identity documents securely here: {{portal_url}}. Reply Hi to choose your WhatsApp stay-update preferences and get help. Offers are optional.",
  "booking_changed": "Hello {{guest_name}}, your reservation at {{hotel_name}} has been updated. Please review the latest details for booking {{booking_reference}} before travelling. Your check-in date is {{check_in}}, with check-in available from {{check_in_time}}. Your check-out date is {{check_out}}, with checkout due by {{check_out_time}}. Your assigned room is {{room_name}}. If any detail needs attention, reply Hi to speak with reception about your stay.",
  "booking_cancelled": "Hello {{guest_name}}, booking {{booking_reference}} at {{hotel_name}} has been cancelled. Contact reception if you need assistance.",
  "checked_in": "Hello {{guest_name}}, your check-in at {{hotel_name}} is complete. Your assigned room is {{room_name}}, and your booking reference is {{booking_reference}}. Your scheduled check-out is {{check_out}}, with checkout due by {{check_out_time}}. Send Hi or Hello whenever you need food, fresh towels, cleaning, repairs or help from reception during your stay.",
  "checked_out": "Hello {{guest_name}}, checkout for booking {{booking_reference}} at {{hotel_name}} is complete. Thank you for staying with us. Please share your honest feedback about this stay using the review button. We hope to welcome you again.",
  "arrival_reminder": "Hello {{guest_name}}, your check-in at {{hotel_name}} is today, {{check_in}}, from {{check_in_time}}. Booking: {{booking_reference}}. Approved identity documents and a ready room are required. Reply CHECK IN to review and confirm check-in here on WhatsApp, or Hi for help.",
  "checkout_reminder": "Hello {{guest_name}}, checkout from {{hotel_name}}, room {{room_name}}, is due {{check_out}} by {{check_out_time}}. Reply CHECKOUT to review your bill and confirm check-out here. Reception can help with payment or late checkout.",
  "review_request": "Hello {{guest_name}}, thank you for staying at {{hotel_name}}. If you would like to share your experience, leave a review here: {{review_url}}. Thank you for your feedback.",
  "order_placed": "Hello {{guest_name}}, the team at {{hotel_name}} has received your food order. Your order reference is {{order_reference}}, and the delivery room is {{room_name}}. Here is a summary of the items requested: {{order_summary}}. The recorded order total is {{amount}} {{currency}}. We will send further updates as the kitchen prepares your order. Reply Hi if you need help with this request.",
  "order_preparing": "Hello {{guest_name}}, the kitchen at {{hotel_name}} has started preparing your food order. The order reference is {{order_reference}}. Your requested items are: {{order_summary}}. The delivery room recorded for this order is {{room_name}}. We will send another update when it is ready. Contact reception if you need assistance with your order.",
  "order_ready": "Hello {{guest_name}}, your food order at {{hotel_name}} is now ready. The order reference is {{order_reference}}, with these items prepared: {{order_summary}}. The room recorded for this order is {{room_name}}. Please contact reception if you need help arranging collection or delivery, or if any detail of the order needs attention.",
  "order_served": "Hello {{guest_name}}, the team at {{hotel_name}} has marked your food order as delivered. Your order reference is {{order_reference}}, and the delivery room is {{room_name}}. The delivered items are: {{order_summary}}. The recorded total for this order is {{amount}} {{currency}}. Please contact reception if an item is missing or you need further help. Send Hi to open the guest menu.",
  "order_cancelled": "Hello {{guest_name}}, order {{order_reference}} at {{hotel_name}} has been cancelled. Contact reception if you need assistance.",
  "request_received": "Hello {{guest_name}}, {{hotel_name}} received your request: {{request_title}}. Room: {{room_name}}. Our team will keep you updated here. Send reception to add details.",
  "request_started": "Hello {{guest_name}}, the team at {{hotel_name}} has started working on your service request. The request recorded is: {{request_title}}. The room linked to this request is {{room_name}}. We will send a further update when the work is completed. Reply reception if you need to add information or speak with a member of staff.",
  "request_completed": "Hello {{guest_name}}, the team at {{hotel_name}} has marked your service request as completed. The request was: {{request_title}}. The room linked to this request is {{room_name}}. Please contact reception if you still need assistance or the request needs further attention. Send Hi to open the guest menu for more help.",
  "request_cancelled": "Hello {{guest_name}}, your request at {{hotel_name}} was cancelled: {{request_title}}. Contact reception if you need assistance.",
  "payment_received": "Hello {{guest_name}}, the team at {{hotel_name}} has recorded a payment for your stay. The amount recorded is {{amount}} {{currency}}, against booking {{booking_reference}}. Reply Hi and choose My bill to review your itemized statement and any remaining balance. If the payment details need attention or you would like a receipt, please contact reception.",
  "payment_refunded": "Hello {{guest_name}}, the team at {{hotel_name}} has recorded a refund for your booking. The refund amount recorded is {{amount}} {{currency}}, against booking {{booking_reference}}. The time it takes to reach your account depends on the payment provider. Please contact reception if you need the refund reference or help reviewing the recorded details.",
  "invoice_issued": "Hello {{guest_name}}, the team at {{hotel_name}} has issued an invoice for your stay. The invoice reference is {{invoice_number}}, and its recorded total is {{amount}} {{currency}}. This invoice relates to booking {{booking_reference}}. You can review the secure itemized bill here: {{portal_url}}. Please contact reception if you have questions about any charge or need help with the invoice details.",
  "documents_received": "Hello {{guest_name}}, {{hotel_name}} received your identity documents for booking {{booking_reference}}. They are being checked securely. We will confirm when the required review is complete; check-in remains pending until approval.",
  "documents_approved": "Hello {{guest_name}}, {{hotel_name}} approved your required identity documents. Booking: {{booking_reference}}. Check-in: {{check_in}} from {{check_in_time}}; check-out: {{check_out}} by {{check_out_time}}. Reply CHECK IN when you arrive, or Hi for help. Your room must be ready before check-in.",
  "documents_rejected": "Hello {{guest_name}}, {{hotel_name}} needs a replacement identity document for booking {{booking_reference}}. Upload it securely here: {{portal_url}}. Please contact reception for review details; do not send ID numbers into this chat.",
  "order_feedback": "Hello {{guest_name}}, how was food order {{order_reference}} delivered by {{hotel_name}}? Reply RATE FOOD to rate your completed order here on WhatsApp. Your feedback helps our kitchen improve.",
  "request_feedback": "Hello {{guest_name}}, how was your completed request at {{hotel_name}}: {{request_title}}? Reply RATE SERVICE to rate the service here on WhatsApp. Thank you for your feedback.",
  "order_serving": "Hello {{guest_name}}, the team at {{hotel_name}} is bringing your food order {{order_reference}} to your room. Please let reception know if you need anything else while we serve your meal.",
  "booking_deposit_requested": "Hello {{guest_name}}, your room request at {{hotel_name}} is awaiting a 50% deposit of {{amount}} {{currency}}. Booking reference: {{booking_reference}}. Please use the secure payment link sent in this chat before the 15-minute hold ends. Your booking is not confirmed until payment is verified.",
  "booking_deposit_paid": "Hello {{guest_name}}, {{hotel_name}} has verified your booking deposit of {{amount}} {{currency}} for booking {{booking_reference}}. Thank you. Your booking confirmation and secure identity-upload instructions are sent separately in this chat. The remaining room balance and any extras are payable later.",
  "booking_payment_expired": "Hello {{guest_name}}, the payment hold for booking request {{booking_reference}} at {{hotel_name}} has expired. The room is no longer held and this booking is not confirmed. Please send BOOK for current availability. If you have already paid, contact reception before paying again.",
  "booking_payment_failed": "Hello {{guest_name}}, payment for booking request {{booking_reference}} at {{hotel_name}} could not be verified. Please do not create multiple payments. Contact reception for help, or use the current secure link only while your room hold is active."
};
export const menuServices=[
  {
    "key": "stay",
    "label": "My stay",
    "group": "My stay",
    "action": "reply",
    "body": "Here are the details recorded for your stay at {{hotel_name}}. Your booking reference is {{booking_reference}}, and your assigned room is {{room_name}}. Your scheduled check-in date is {{check_in}}, and your check-out date is {{check_out}}. Please review these details before travelling. Reply Hi to open the guest menu or contact reception if any booking detail needs attention."
  },
  {
    "key": "documents",
    "label": "Upload documents",
    "group": "My stay",
    "action": "reply",
    "body": "Hello {{guest_name}}, upload documents for booking {{booking_reference}} securely: {{portal_url}}. The hotel will confirm review here. Please do not send identity files into this chat."
  },
  {
    "key": "checkin",
    "label": "Check in",
    "group": "My stay",
    "action": "reply",
    "body": "Hello {{guest_name}}, let us review check-in for booking {{booking_reference}} at {{hotel_name}}. Documents must be approved and your room must be ready before you confirm."
  },
  {
    "key": "checkout",
    "label": "Check out",
    "group": "My stay",
    "action": "reply",
    "body": "Hello {{guest_name}}, let us prepare checkout for booking {{booking_reference}} at {{hotel_name}}. Your bill and unfinished orders are checked before checkout confirmation."
  },
  {
    "key": "bill",
    "label": "My bill",
    "group": "My stay",
    "action": "reply",
    "body": "Hello {{guest_name}}, your private bill for booking {{booking_reference}} is here: {{portal_url}}. Contact reception if you need help."
  },
  {
    "key": "food",
    "label": "Order food",
    "group": "Food & services",
    "action": "reply",
    "body": "Hello {{guest_name}}, choose food for your stay at {{hotel_name}} here: {{portal_url}}. Order confirmation and delivery updates will arrive on WhatsApp."
  },
  {
    "key": "services",
    "label": "Request a service",
    "group": "Food & services",
    "action": "reply",
    "body": "Hello {{guest_name}}, choose the help you need at {{hotel_name}}. No service request is placed until you confirm the details here on WhatsApp."
  },
  {
    "key": "location",
    "label": "Hotel location",
    "group": "Hotel information",
    "action": "reply",
    "body": "Here are the directions to {{hotel_name}}. Use the directions button to plan your arrival. Reception can help if you need assistance."
  },
  {
    "key": "photos",
    "label": "Hotel photos",
    "group": "Hotel information",
    "action": "reply",
    "body": "Here are some photos of {{hotel_name}} to help you recognise the hotel and plan your visit. Send Hi for more help."
  },
  {
    "key": "website",
    "label": "Hotel website",
    "group": "Hotel information",
    "action": "reply",
    "body": "Visit the website of {{hotel_name}} using the button below. Reception can help with any questions about your stay."
  },
  {
    "key": "review",
    "label": "Leave a review",
    "group": "Hotel information",
    "action": "reply",
    "body": "Thank you for visiting {{hotel_name}}. You are welcome to share an honest review of your experience using the button below."
  },
  {
    "key": "reception",
    "label": "Talk to reception",
    "group": "Reception",
    "action": "reception",
    "body": "Thank you for contacting {{hotel_name}}. Reception has been notified and a team member will reply here. Automatic chat replies pause during staff handling."
  }
];
// Previously approved starter wording remains valid; owner edits are still preserved.
export const legacyStarterBodies={
  "booking_changed": "Hello {{guest_name}}, your booking {{booking_reference}} at {{hotel_name}} has changed. Arrival: {{check_in}} from {{check_in_time}}. Departure: {{check_out}} by {{check_out_time}}. Room: {{room_name}}. Reply Hi for help.",
  "checked_in": "Hello {{guest_name}}, you are checked in at {{hotel_name}}. Room: {{room_name}}. Booking: {{booking_reference}}. Checkout: {{check_out}} by {{check_out_time}}. Send Hi or Hello for food, towels, cleaning, repairs or reception assistance.",
  "order_placed": "Hello {{guest_name}}, {{hotel_name}} received order {{order_reference}} for room {{room_name}}: {{order_summary}}. Total: {{amount}} {{currency}}. We will keep you updated as the kitchen prepares it. Send Hi for help.",
  "order_preparing": "Hello {{guest_name}}, the kitchen at {{hotel_name}} is preparing order {{order_reference}}: {{order_summary}}. Delivery room: {{room_name}}. Send reception if you need to speak to the team.",
  "order_ready": "Hello {{guest_name}}, order {{order_reference}} at {{hotel_name}} is ready: {{order_summary}}. Room: {{room_name}}. Contact reception if you need assistance.",
  "order_served": "Hello {{guest_name}}, order {{order_reference}} has been delivered to room {{room_name}} at {{hotel_name}}: {{order_summary}}. Total: {{amount}} {{currency}}. Send Hi if you need anything else.",
  "request_started": "Hello {{guest_name}}, the team at {{hotel_name}} is working on your request: {{request_title}}. Room: {{room_name}}. We will confirm completion here.",
  "request_completed": "Hello {{guest_name}}, your request at {{hotel_name}} is complete: {{request_title}}. Room: {{room_name}}. Send Hi if you need further help.",
  "payment_received": "Hello {{guest_name}}, {{hotel_name}} received {{amount}} {{currency}} for booking {{booking_reference}}. Reply Hi and choose My bill for your itemized statement. Thank you.",
  "payment_refunded": "Hello {{guest_name}}, {{hotel_name}} recorded a refund of {{amount}} {{currency}} for booking {{booking_reference}}. Contact reception for processing details.",
  "invoice_issued": "Hello {{guest_name}}, {{hotel_name}} issued invoice {{invoice_number}} for {{amount}} {{currency}}, booking {{booking_reference}}. Your secure itemized bill: {{portal_url}}. Contact reception if you have questions.",
  "menu_stay": "Here are the details for booking {{booking_reference}} at {{hotel_name}}. Arrival: {{check_in}}. Departure: {{check_out}}. Room: {{room_name}}. Send Hi for more help."
};
export const starterSlots=[...Object.keys(eventBodies).map(key=>({key,event:key,kind:'event',delay:key==='arrival_reminder'?180:key==='checkout_reminder'?120:key==='order_feedback'?20:key==='request_feedback'?5:0,activate:key!=='review_request'})),...menuServices.map(service=>({...service,key:'menu_'+service.key,native_action:service.key,kind:'menu',activate:true}))];
export function templateName(pid,key,version=1){if(!/^[a-f0-9-]{36}$/i.test(pid)||!starterSlots.some(s=>s.key===key)||!Number.isSafeInteger(version)||version<1)throw Error('Invalid default template slot.');return `hp_${pid.replaceAll('-','')}_${key}_v${version}`;}
export function starterTemplate(slot,context){
 const service=slot.kind==='menu'?menuServices.find(s=>'menu_'+s.key===slot.key):null;
 let text=service?.body??eventBodies[slot.key];if(!text)throw Error('Unknown hotel template.');
 const names=[...new Set([...text.matchAll(/\{\{([a-z_]+)\}\}/g)].map(x=>x[1]))],sample={guest_name:'Alex',hotel_name:'Seaside Hotel',booking_reference:'DEMO1234',check_in:'01-12-2026',check_out:'03-12-2026',room_name:'Deluxe 101',check_in_time:'14:00',check_out_time:'11:00',portal_url:'https://hotel.example/s/sample/documents',review_url:'https://hotel.example/review',hotel_phone:'+919000000000',order_reference:'ORDER123',order_summary:'2 sandwiches',request_title:'Extra towels',amount:'500.00',currency:'INR',invoice_number:'INV123',event_label:'Stay update'};
 const components=[{type:'BODY',text,...(names.length?{example:{body_text_named_params:names.map(param_name=>({param_name,example:sample[param_name]}))}}:{})}];
 const buttons=[];
 if(slot.key==='booking_confirmed'||slot.key==='menu_photos'){if(!context.imageHandle)throw Error('A welcome photo collage is required.');components.unshift({type:'HEADER',format:'IMAGE',example:{header_handle:[context.imageHandle]}});}
 const link=slot.key==='booking_confirmed'||slot.key==='menu_location'?context.links.maps_url:slot.key==='checked_out'||slot.key==='menu_review'?context.links.review_url:slot.key==='menu_website'?context.links.website_url:null;
 if(link){const u=new URL(link);if(u.protocol!=='https:'||u.username||u.password||u.hash||u.pathname.includes('/s/')||u.searchParams.has('token')||u.searchParams.has('access_token'))throw Error('Public HTTPS hotel links required.');buttons.push({type:'URL',text:slot.key==='booking_confirmed'||slot.key==='menu_location'?'Get directions':slot.key==='menu_website'?'Visit website':'Leave a review',url:link});}
 if(buttons.length)components.push({type:'BUTTONS',buttons});
 return{name:templateName(context.property_id,slot.key,slot.version??1),language:'en_US',category:slot.key==='review_request'?'MARKETING':'UTILITY',...(names.length?{parameter_format:'NAMED'}:{}),components};
}

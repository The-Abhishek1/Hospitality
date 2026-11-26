import './policy.css';

const contact = 'admin@xcloak.tech';
const updated = '26 November 2026';
const sections = [
  {id:'scope',title:'Who this policy covers',paragraphs:[
    'Hospitality is a hotel management and guest messaging service operated under the Xcloak name. This policy covers the Hospitality hotel app, secure guest pages, and connected messaging features. Contact Xcloak at admin@xcloak.tech about this policy.',
    'Hotels choose how to use guest information for their bookings and operations. Xcloak provides the software and processes that information to deliver the service for the hotel. For your reservation, identity documents, bill, or a hotel’s marketing preferences, contact the hotel first. Contact Xcloak for platform account questions or help reaching the hotel. A hotel’s own privacy notice may also apply.'
  ]},
  {id:'collection',title:'Information we process',paragraphs:[
    'Hotel accounts and teams: names, email addresses, authentication records, business and property details, staff roles, invitations, and account activity.',
    'Guest stays: contact details, reservation dates, room assignments, occupant details, arrival information, identity details and uploaded documents, staff verification decisions, food orders, service requests, feedback, invoices, and payment records.',
    'WhatsApp: guest phone numbers and profile names, message content and supported attachments, menu choices, delivery and read statuses, messaging preferences, permission records, and number-verification events. For connected hotels, we process business account and phone identifiers, template information, and authorization credentials.',
    'If a hotel connects an existing WhatsApp Business app account, authorized contact information and chat history may be imported when shared through Meta’s onboarding flow. Phone-app message echoes help keep the hotel’s Inbox in sync. Importing a contact or old chat does not create marketing permission.',
    'Technical information: session cookies, device and browser information, IP addresses and request logs handled by our hosting and service providers, security events, and operational error records. We also process information you provide when requesting support.'
  ]},
  {id:'use',title:'How information is used',paragraphs:[
    'We use information to create and secure accounts; give staff access to the correct hotel; manage reservations, document review, check-in, checkout, dining, housekeeping, and guest requests; prepare bills; reconcile payments; and provide support.',
    'Hotels use enabled messaging features to send booking and stay updates, respond to guests, and run campaigns for guests with the appropriate permission. We record permissions, withdrawals, delivery results, and relevant staff actions to operate these features and investigate problems.',
    'We also use necessary records to protect the service, prevent misuse, resolve disputes, and meet applicable obligations. Connecting a Meta account does not give Hospitality access to your Facebook password.'
  ]},
  {id:'choices',title:'WhatsApp choices and marketing',paragraphs:[
    'Booking contact permission, ongoing stay updates, and optional offers are recorded separately. A hotel must have the appropriate permission before starting a conversation or sending campaigns. Required template approval and messaging windows are enforced where applicable.',
    'Guests can change their messaging preferences in the hotel’s WhatsApp conversation, send STOP to withdraw automated messaging permission, or contact reception. Withdrawal affects future messages; a message already being delivered may still arrive. Hotels may still need to contact you through another appropriate channel about your booking.',
    'Hotel administrators can disconnect a sender through WhatsApp Connection. Disconnecting stops messaging through Hospitality and removes the saved connection token; it does not delete the Meta account or the hotel’s existing records. Partner access can also be managed in Meta’s business settings.'
  ]},
  {id:'sharing',title:'Who receives information',paragraphs:[
    'Authorized hotel staff can access information according to their hotel and role. Platform administrators may access information when needed to operate the service, resolve support requests, or investigate security issues.',
    'Service providers process information needed for their functions: Supabase for authentication, database and file storage; Vercel for hosting; Resend for account and invitation emails; Meta and WhatsApp for account connections, templates and messaging; and Razorpay for payments when a hotel enables it. A hotel’s connected booking or distribution providers may exchange reservation and inventory information when that integration is used.',
    'We do not sell personal information. Information may also be disclosed when required by applicable legal process or to protect people, the service, or legitimate rights. Providers and hotels may have their own privacy notices governing their separate services.'
  ]},
  {id:'payments',title:'Payments and identity documents',paragraphs:[
    'When online payment is enabled, payment details are submitted to the payment provider through its payment flow. Hospitality records payment references, amounts, currency, status, and related bill entries; it does not require guests to send card details or payment PINs in WhatsApp.',
    'Identity uploads are used for the hotel’s verification process. Supported file checks depend on the configured review method; preparing a photo for review is not an antivirus guarantee. Access to uploaded documents is restricted to authorized workflows. Do not send identity files, passwords, API keys, or payment credentials to our privacy email address.'
  ]},
  {id:'storage',title:'Storage, security and retention',paragraphs:[
    'We use HTTPS, role-based access controls, private storage workflows, and encryption for saved integration credentials. Secure guest links provide access to a specific booking task; treat them as private and share them only with the intended guest. No online system can guarantee absolute security.',
    'Information may be processed in countries where Xcloak’s service providers operate. A hotel’s location does not mean all processing occurs in that country.',
    'Retention depends on the information and purpose, including the hotel’s operations, account status, legal recordkeeping requirements, dispute handling, and security needs. There is no single automatic deletion period for every record. Archiving a hotel preserves records and is not a deletion request. Contact the hotel or Xcloak to ask about retention or request deletion. Backup copies may remain until the provider’s normal backup lifecycle removes them.'
  ]},
  {id:'cookies',title:'Cookies and browser storage',paragraphs:[
    'The hotel app uses session cookies to keep staff signed in and maintain secure authentication. Guest pages use private stay links to authorize the requested task. Browser storage and service workers may support the app experience; private guest task data is not intentionally cached for offline use.',
    'You can manage cookies through your browser. Blocking necessary cookies may prevent sign-in or other essential functions. Connected provider pages may use their own cookies under their policies.'
  ]},
  {id:'rights',title:'Access, correction and deletion requests',paragraphs:[
    'You can ask for access to, correction of, or deletion of your information, withdraw messaging permission, or raise a privacy concern. Which requests can be fulfilled depends on the information, the hotel’s responsibilities, and applicable requirements. Contact your hotel for stay records, or email admin@xcloak.tech for platform information and assistance.',
    'We may ask for a proportionate way to confirm your identity and authority before sharing or deleting information. We will explain if information must be retained, for example for billing, legal obligations, security, or a dispute. Deleting information held by Hospitality does not automatically delete copies held independently by the hotel, Meta, your WhatsApp app, or other providers. See our data deletion instructions for the request steps.'
  ]},
  {id:'children',title:'Children and changes to this policy',paragraphs:[
    'Staff accounts are intended for adults authorized to manage a hotel. Hotels may enter children’s occupant details when needed for a family reservation. A parent or guardian should contact the hotel about a child’s information.',
    'We may update this policy as the service changes. The date above identifies the current version. We will provide additional notice where appropriate for material changes.'
  ]}
];

export function PolicyPage({deletion=false}:{deletion?:boolean}) {
  return <main className="legal-page">
    <header className="legal-header"><a className="legal-brand" href="https://xcloak-hospitality.vercel.app/login"><span aria-hidden="true">h·</span>hospitality.</a><nav aria-label="Privacy pages"><a href="/privacy" aria-current={!deletion?'page':undefined}>Privacy policy</a><a href="/data-deletion" aria-current={deletion?'page':undefined}>Data deletion</a></nav></header>
    <article className="legal-document">
      <div className="legal-heading"><p className="legal-eyebrow">XCLOAK · HOSPITALITY</p><h1>{deletion?'Data deletion instructions':'Privacy policy'}</h1><p>Last updated <time dateTime="2026-11-26">{updated}</time></p></div>
      {deletion?<div className="legal-content">
        <section><h2>Request deletion of your information</h2><p>You can request deletion without signing in to Hospitality. Email <a href={`mailto:${contact}?subject=Hospitality%20data%20deletion%20request`}>{contact}</a> with the subject <strong>Hospitality data deletion request</strong>.</p><ol><li>Tell us whether you are a guest, hotel account holder, or team member.</li><li>Include your account email or WhatsApp number with country code, the hotel name, and a booking reference if relevant. Send only what is needed to locate your records.</li><li>Describe what you want deleted, such as your platform account, Meta connection data, uploaded documents, or guest conversation records.</li></ol><p>Do not attach identity documents, passwords, access tokens, card details, or payment PINs. We will contact you if further identity or authority checks are needed.</p></section>
        <section><h2>Guest and hotel records</h2><p>Contact the hotel directly about records it manages for your stay. Xcloak can help route your request and, where appropriate, act with the hotel’s authorization. An account holder cannot delete another guest’s information without authority.</p><p>We will assess your request, explain what can be removed, and let you know the outcome. Billing, legal, security, or dispute records may need to be retained; we will explain relevant limitations. Backup copies may remain until the provider’s normal backup lifecycle removes them.</p></section>
        <section><h2>Disconnecting Meta or WhatsApp</h2><p>A hotel administrator can open <strong>WhatsApp Connection → Reconnect or disconnect → Disconnect</strong> to stop Hospitality messaging and remove the saved connection token. You can also remove partner access through Meta’s business settings.</p><p>Disconnecting, removing partner access, or archiving a property does not by itself delete stored conversations or hotel records. Use the email request above to request deletion of data held by Hospitality. These instructions do not delete your Facebook account, WhatsApp account, or copies held independently by Meta, the hotel, or other recipients.</p></section>
        <section><h2>Stop automated WhatsApp messages</h2><p>Send <strong>STOP</strong> to the hotel’s connected WhatsApp number or ask reception to update your preferences. Withdrawing messaging permission stops future automated messages; it is separate from requesting deletion of historical records.</p></section>
        <p>Read the <a href="/privacy">privacy policy</a> for the information we process and how it is used.</p>
      </div>:<div className="legal-layout"><nav className="legal-contents" aria-label="Policy contents"><strong>On this page</strong>{sections.map(s=><a key={s.id} href={`#${s.id}`}>{s.title}</a>)}</nav><div className="legal-content">{sections.map(s=><section key={s.id} id={s.id}><h2>{s.title}</h2>{s.paragraphs.map((p,i)=><p key={i}>{p}</p>)}</section>)}<section id="contact"><h2>Contact Xcloak</h2><p>Email <a href={`mailto:${contact}`}>{contact}</a> for privacy questions, or follow the <a href="/data-deletion">data deletion instructions</a>.</p></section></div></div>}
    </article>
    <footer className="legal-footer"><span>Hospitality by Xcloak</span><a href={`mailto:${contact}`}>{contact}</a></footer>
  </main>;
}

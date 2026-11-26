import Link from 'next/link';
import {createClient} from '@/lib/supabase/server';
import {onboardingReady,graphVersion} from '@/lib/whatsapp-onboarding';
import {WhatsAppConnect} from '@/components/whatsapp/connect';
import {CoexistenceProgress} from '@/components/whatsapp/coexistence-progress';
import './whatsapp.css';
export const metadata={title:'WhatsApp Connection · Hospitality'};
export default async function WhatsAppPage({params}:{params:Promise<{propertyId:string}>}){
 const {propertyId:pid}=await params,db=await createClient(),{data,error}=await db.rpc('whatsapp_setup_context',{p_property:pid});
 if(error)return <section><h1>WhatsApp Connection</h1><p>Connection settings are unavailable. Refresh or ask your hotel owner for access.</p><Link href={`/p/${pid}/inbox`}>Back to Inbox</Link></section>;
 const{data:transferChoices}=await db.rpc('whatsapp_transfer_choices',{p_property:pid});
 const c=data.connection,ready=onboardingReady(),connected=c?.status==='active';
 return <div className="wa-workspace">
  <header className="wa-heading"><div><h1>WhatsApp Connection</h1><p>Manage the number your hotel uses to talk to guests.</p></div><Link className="dash-button dash-secondary" href={`/p/${pid}/inbox`}>Open Inbox →</Link></header>
  <section className="wa-card wa-account" aria-labelledby="wa-number-heading">
   <div className="wa-account-heading"><div><span className="dash-eyebrow">YOUR HOTEL’S NUMBER</span><h2 id="wa-number-heading">{c?.display_phone??'Connect WhatsApp'}</h2></div><span className={`wa-badge ${connected?'connected':''}`}>{connected?'Connected in Hospitality':c?'Disconnected':'Not connected'}</span></div>
   <p>{connected?'Check account access, then use Inbox to follow guest conversations.':'Sign in with Meta to select your hotel’s WhatsApp Business account and verify its number.'}</p>
   {c&&!c.managed&&<p className="wa-notice">This connection was set up manually. Reconnect with Meta to enable secure account management.</p>}
   {!ready&&<div className="wa-notice"><strong>Platform setup required</strong><p>Ask your platform administrator to finish Meta Embedded Signup and HTTPS settings. Existing manual Inbox connections continue to work.</p></div>}
   <WhatsAppConnect transferChoices={transferChoices??[]} pid={pid} appId={process.env.WHATSAPP_APP_ID??''} configId={process.env.WHATSAPP_CONFIG_ID??''} version={graphVersion} ready={ready} connected={connected} existing={Boolean(c)} connectionMode={c?.mode} displayPhone={c?.display_phone??''}/>
   {data.coexistence&&<CoexistenceProgress pid={pid} status={data.coexistence} active={connected}/>}
  </section>
  <Link className="wa-next" href={`/p/${pid}/automations`}><div><strong>{connected?'Set up guest messages':'Prepare your guest messages'}</strong><p>Manage templates, guest menus and automatic event messages.</p></div><span aria-hidden="true">→</span></Link>
  <details className="wa-card wa-help"><summary>Connection help & requirements</summary><div className="wa-help-content"><h3>Before connecting</h3><ul><li>A Meta login with access to your hotel’s business assets.</li><li>Your hotel’s WhatsApp number and access to its verification method.</li><li>A Meta payment method for applicable messaging charges.</li></ul><p>Choose Keep using WhatsApp Business app for a number already used on your hotel’s phone. Hospitality does not register or delete that number. Meta must approve the app for Coexistence, including Tech Provider and Advanced Access requirements; this option cannot bypass a Meta eligibility error. History sharing is optional. Keep the phone app open until synchronization finishes. Meta may unlink companion devices during setup; supported devices can be linked again afterward.</p><h3>One number per hotel</h3><p>A number can be active in one hotel at a time. Move an existing managed connection here if you administer both hotels, or disconnect the old hotel before connecting with Meta. Conversation history stays in its original hotel.</p><h3>Check delivery</h3><p>Check connection validates access and subscriptions. To confirm delivery, send a message from another phone and reply through Inbox.</p><h3>Disconnecting</h3><p>Disconnect removes Hospitality’s saved token and stops messaging here. It preserves conversations and does not delete your Meta account. Remove partner access separately in Meta if required.</p></div></details>
 </div>;
}

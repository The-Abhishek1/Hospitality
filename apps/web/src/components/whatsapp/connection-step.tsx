import {WhatsAppConnect} from './connect';
import {CoexistenceProgress} from './coexistence-progress';
type Props=React.ComponentProps<typeof WhatsAppConnect>&{context:{connection?:{status:string;display_phone?:string;managed?:boolean;mode?:string};coexistence?:React.ComponentProps<typeof CoexistenceProgress>['status']}|null;error:boolean};
export function WhatsAppConnectionStep({context,error,...props}:Omit<Props,'connected'|'existing'|'connectionMode'|'displayPhone'>){
 const c=context?.connection,connected=c?.status==='active';
 return <details className="wa-step" open={!connected} key={`connection-${connected}`}><summary><span className="wa-step-number">1</span><span><strong>Connect your number</strong><small>{connected?`${c.display_phone??'Hotel number'} · Connected`:'Use your hotel’s WhatsApp Business number.'}</small></span><span className="wa-step-state">{connected?'Connected':'Start here'}</span></summary><div className="wa-step-body">
 {error?<p role="alert">Connection settings could not load. Refresh or ask the hotel owner for access.</p>:<>
 {!props.ready&&<p className="wa-notice">The platform administrator needs to finish Meta connection settings. Existing connections can still receive messages.</p>}
 {c&&!c.managed&&<p className="wa-notice">This number was connected manually. Reconnect with Meta to manage it securely here.</p>}
 <WhatsAppConnect {...props} connected={connected} existing={Boolean(c)} connectionMode={c?.mode} displayPhone={c?.display_phone??''}/>
 {context?.coexistence&&<CoexistenceProgress pid={props.pid} status={context.coexistence} active={connected}/>}
 <details className="wa-advanced"><summary>Connection help</summary><p>Sign in with the Meta account that manages this hotel’s number. Keep WhatsApp Business open while connecting an existing phone app. One number can serve one hotel at a time.</p><p>Check connection verifies account access. To test a conversation, send Hi from another phone and open Inbox.</p><p>Disconnect stops messaging in Hospitality and removes its saved access token. Your conversation history and external Meta account remain.</p></details>
 </>}
 </div></details>;
}

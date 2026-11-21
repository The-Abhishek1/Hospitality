import { XMLParser, XMLValidator } from 'fast-xml-parser';
import type { ChannelAdapter, ConnectionCtx, AvailabilityPush, NormalizedEvent } from '../adapter.js';

export type SupplyCredentials = { provider: 'agoda' | 'booking_com'; clientId: string; clientSecret: string; environment: 'sandbox'; };
export type Fetch = typeof fetch;
const parser = new XMLParser({ ignoreAttributes: false, parseTagValue: false, processEntities: false });
export function parseXml(text: string): Record<string, any> {
  if (text.length > 2_000_000 || /<!DOCTYPE|<!ENTITY/i.test(text) || XMLValidator.validate(text) !== true) throw new Error('Invalid provider XML response');
  return parser.parse(text);
}
export function identifier(value: string | null | undefined): string {
  if (!value || !/^[1-9][0-9]{0,19}$/.test(value)) throw new Error('A numeric provider property / room ID is required');
  return value;
}
export function validateDays(push: AvailabilityPush, max: number) {
  identifier(push.externalRoomId);
  if (!push.days.length || push.days.length > 730) throw new Error('Availability must contain 1–730 nights');
  const seen = new Set<string>();
  for (const d of push.days) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(d.day) || !Number.isFinite(Date.parse(d.day)) || new Date(d.day).toISOString().slice(0,10) !== d.day || seen.has(d.day)) throw new Error('Invalid or duplicate availability date');
    if (!Number.isInteger(d.available) || d.available < 0 || d.available > max) throw new Error(`Inventory outside provider range 0–${max}`);
    seen.add(d.day);
  }
}
export function availabilityXml(provider: 'agoda' | 'booking_com', hotel: string, push: AvailabilityPush): string {
  identifier(hotel); validateDays(push, provider === 'booking_com' ? 254 : 999);
  // Explicit dates avoid the providers' different date-range end semantics. No stop-sell flag is changed.
  if (provider === 'agoda') return `<request timestamp="${Date.now()}" type="10"><criteria property_id="${hotel}"><inventory>${push.days.map(d=>`<update room_id="${push.externalRoomId}"><date_range from="${d.day}" to="${d.day}"/><allotment>${d.available}</allotment></update>`).join('')}</inventory></criteria></request>`;
  return `<request><room id="${push.externalRoomId}">${push.days.map(d=>`<date value="${d.day}"><roomstosell>${d.available}</roomstosell></date>`).join('')}</room></request>`;
}

// Availability-only certification implementation. Never claims reservation or pricing support.
// Real traffic is disabled unless a server operator enables sandbox testing explicitly.
export class SupplyAdapter implements ChannelAdapter {
  private token?: { value: string; expires: number };
  private tokenPending?: Promise<string>;
  constructor(readonly provider: 'agoda' | 'booking_com', private resolve: (ref: string) => SupplyCredentials,
    private enabled: boolean, private http: Fetch = fetch) {}
  private async request(url: string, init: RequestInit): Promise<Response> {
    try { return await this.http(url, { ...init, redirect: 'error', signal: AbortSignal.timeout(20000) }); }
    catch { throw new Error(`${this.provider}: network request failed or timed out`); }
  }
  private async accessToken(c: SupplyCredentials, force = false): Promise<string> {
    if (!force && this.token && this.token.expires > Date.now()) return this.token.value;
    if (this.tokenPending) return this.tokenPending;
    this.tokenPending = (async () => {
      const agoda = this.provider === 'agoda';
      const response = await this.request(agoda ? 'https://supply.agoda.com/token-based-authentication/v2/exchange' : 'https://connectivity-authentication.booking.com/token-based-authentication/exchange', {
        method:'POST', headers:{'Content-Type':agoda?'application/x-www-form-urlencoded':'application/json'},
        body:agoda ? new URLSearchParams({grant_type:'client_credentials',client_id:c.clientId,client_secret:c.clientSecret}).toString() : JSON.stringify({client_id:c.clientId,client_secret:c.clientSecret}),
      });
      if (!response.ok) throw new Error(`${this.provider}: authentication HTTP ${response.status}`);
      let body: any; try { body = await response.json(); } catch { throw new Error('Invalid authentication response'); }
      const value = agoda ? body.access_token : body.jwt;
      if (typeof value !== 'string' || !value || value.length > 16000) throw new Error('Missing provider access token');
      if (!agoda) {
        let claims: any;
        try { claims = JSON.parse(Buffer.from(value.split('.')[1], 'base64url').toString()); } catch { throw new Error('Invalid Booking.com token'); }
        if (claims.test !== true && claims.test !== 'true') throw new Error('Booking.com requires a test machine account');
      }
      const seconds = agoda ? Number(body.expires_in) : 3600;
      if (!Number.isFinite(seconds) || seconds < 60) throw new Error('Invalid token lifetime');
      this.token = {value, expires:Date.now() + Math.min(seconds - 30, 3300)*1000};
      return value;
    })();
    try { return await this.tokenPending; } finally { this.tokenPending = undefined; }
  }
  protected async xmlRequest(ctx: ConnectionCtx, path: string, body: string): Promise<Record<string, any>> {
    if (!this.enabled || ctx.environment !== 'sandbox') throw new Error('Provider sandbox traffic is disabled');
    identifier(ctx.externalPropertyId);
    const c = this.resolve(ctx.credentialsRef ?? '');
    if (c.provider !== this.provider || c.environment !== 'sandbox' || !c.clientId || !c.clientSecret) throw new Error('Invalid server credential reference');
    if (Buffer.byteLength(body)>1_000_000) throw new Error('Provider request exceeds size limit');
    const url = this.provider === 'agoda' ? `https://sandbox-supply.agoda.com${path}` : 'https://supply-xml.booking.com/hotels/xml/availability';
    for (let attempt = 0; attempt < 2; attempt++) {
      const token = await this.accessToken(c, attempt > 0);
      const response = await this.request(url, {method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/xml',...(this.provider==='booking_com'?{'Accept-Version':'1.1'}:{})}, body});
      if (response.status === 401 && attempt === 0) continue;
      if (response.status !== 200) throw new Error(`${this.provider}: supply HTTP ${response.status}`);
      const xml = parseXml(await response.text());
      if (xml.error || xml.errors || xml.result?.errors || xml.result?.error) throw new Error(`${this.provider}: supply request rejected`);
      return xml;
    }
    throw new Error(`${this.provider}: authorization failed`);
  }
  async pushAvailability(ctx: ConnectionCtx, push: AvailabilityPush): Promise<void> {
    const xml = await this.xmlRequest(ctx, '/api/v2/ari', availabilityXml(this.provider, identifier(ctx.externalPropertyId), push));
    if (this.provider === 'booking_com') {
      if (!Object.hasOwn(xml,'ok')) throw new Error('booking_com: availability update rejected');
    } else assertAgodaAccepted(xml);
  }
  async fetchEvents(_ctx: ConnectionCtx): Promise<NormalizedEvent[]> { return []; }
}

export function assertAgodaAccepted(xml: Record<string, any>): void {
  const result=xml.result;
  if (!result || typeof result !== 'object' || !result['@_TUID'] || Object.hasOwn(result,'errors') || (result['@_status'] && result['@_status'] !== 'Success')) throw new Error('agoda: update rejected or partially accepted');
}

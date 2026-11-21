import { AgodaAdapter } from './adapters/agoda.js';
import type { ChannelAdapter } from './adapter.js';
import { SupplyAdapter, type SupplyCredentials } from './adapters/supply.js';

export function supplyRegistry(raw: string, enabled: boolean) {
  let credentials: Record<string, SupplyCredentials>;
  try { credentials = JSON.parse(raw); } catch { throw new Error('CHANNEL_CREDENTIALS_JSON must be valid JSON'); }
  if (!credentials || Array.isArray(credentials) || typeof credentials !== 'object') throw new Error('Invalid channel credential configuration');
  const adapters = new Map<string, ChannelAdapter>();
  return (provider: string, ref: string | null): ChannelAdapter | undefined => {
    if (provider !== 'agoda' && provider !== 'booking_com') return undefined;
    if (!ref || !Object.hasOwn(credentials, ref)) throw new Error('Missing server credential reference');
    const key = `${provider}:${ref}`;
    if (!adapters.has(key)) { const resolve = (r:string) => {
      if (!Object.hasOwn(credentials,r)) throw new Error('Missing server credential reference');
      return credentials[r];
    }; adapters.set(key, provider === 'agoda' ? new AgodaAdapter(resolve,enabled) : new SupplyAdapter(provider,resolve,enabled)); }
    return adapters.get(key);
  };
}

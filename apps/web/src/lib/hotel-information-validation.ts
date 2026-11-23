import { publicHotelLink } from './guest-concierge';
import { hotelLinkChoices, type HotelLinks } from './hotel-message-resources';

export type HotelInformationErrors = Partial<Record<keyof HotelLinks | 'reason', string>>;

export function hotelInformationErrors(links: HotelLinks, reason: string): HotelInformationErrors {
  const errors: HotelInformationErrors = {};
  for (const { key } of hotelLinkChoices) {
    const value = links[key].trim();
    if (!value) continue;
    if (value.length > 2000) errors[key] = 'Use a link of 2,000 characters or fewer.';
    else if (/^http:\/\//i.test(value)) errors[key] = 'This link uses http://. Enter an https:// link, or leave this optional field blank.';
    else if (/\/s\/|[?&](?:access_token|token)=/i.test(value)) errors[key] = 'Use a public hotel link. Personal guest links and access tokens do not belong here.';
    else if (!publicHotelLink(value)) errors[key] = 'Enter a public https:// link without credentials, a fragment (#), or a local address.';
  }
  if (reason.trim().length < 3) errors.reason = 'Add a short change reason (at least 3 characters) for the settings history.';
  else if (reason.trim().length > 500) errors.reason = 'Keep the change reason within 500 characters.';
  return errors;
}

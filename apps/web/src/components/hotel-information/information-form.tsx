'use client';
import { useActionState, useRef, useState } from 'react';
import Link from 'next/link';
import { saveHotelInformation, type HotelInformationState } from '@/app/p/[propertyId]/settings/information-actions';
import { hotelLinkChoices, type HotelResources } from '@/lib/hotel-message-resources';
import { hotelInformationErrors, type HotelInformationErrors } from '@/lib/hotel-information-validation';
import { HotelPhotoLibrary } from './photo-library';
import './hotel-information.css';

const linkHelp = {
  maps_url: 'The public map or directions link for your hotel.',
  review_url: 'Use the link to your hotel’s review form. A general Maps link may only open the listing.',
  website_url: 'Use your website’s HTTPS address. If HTTPS is unavailable, leave this optional field blank.',
};

export function HotelInformationForm({ pid, resources }: { pid: string; resources: HotelResources }) {
  const [state, action, pending] = useActionState(saveHotelInformation, {} as HotelInformationState);
  const [links, setLinks] = useState(resources.links);
  const [reason, setReason] = useState('');
  const [issues, setIssues] = useState<HotelInformationErrors>({});
  const form = useRef<HTMLFormElement>(null);
  const errorFor = (key: keyof HotelInformationErrors) => issues[key] ??
    (state.values?.[key] === (key === 'reason' ? reason : links[key]) ? state.fieldErrors?.[key] : undefined);
  function clearIssue(key: keyof HotelInformationErrors) {
    setIssues(current => ({ ...current, [key]: undefined }));
  }

  return <div className="hotel-information">
    <section className="sr-panel">
      <h2>Hotel links</h2>
      <p>Save your hotel’s public destinations once. Choose them when adding template buttons, or use the saved review link through {'{{review_url}}'}.</p>
      <form ref={form} action={action} noValidate onSubmit={event => {
        const errors = hotelInformationErrors(links, reason);
        setIssues(errors);
        const first = Object.keys(errors)[0];
        if (first) {
          event.preventDefault();
          (form.current?.elements.namedItem(first) as HTMLInputElement | null)?.focus();
        }
      }}>
        <input type="hidden" name="pid" value={pid}/>
        <input type="hidden" name="version" value={state.version ?? resources.version}/>
        <fieldset disabled={pending}>
          <div className="hotel-information-links">
            {hotelLinkChoices.map(item => {
              const error = errorFor(item.key);
              return <label key={item.key} htmlFor={`hotel-${item.key}`}>
                <span>{item.label} <span className="hotel-information-optional">(optional)</span></span>
                <input id={`hotel-${item.key}`} name={item.key} type="url" maxLength={2000}
                  value={links[item.key]} onChange={event => {
                    setLinks(current => ({ ...current, [item.key]: event.target.value }));
                    clearIssue(item.key);
                  }} placeholder="https://…" spellCheck={false} autoCapitalize="none"
                  aria-invalid={Boolean(error)} aria-describedby={`hotel-${item.key}-help${error ? ` hotel-${item.key}-error` : ''}`}/>
                <small id={`hotel-${item.key}-help`}>{linkHelp[item.key]}</small>
                {error && <small id={`hotel-${item.key}-error`} className="hotel-information-field-error" role="alert">{error}</small>}
              </label>;
            })}
          </div>
          <small>Template buttons copy the selected URL into the draft. Changing these settings later does not rewrite existing templates or send a message.</small>
          <label htmlFor="hotel-change-reason">
            <span>Change reason <span className="hotel-information-required">(required)</span></span>
            <input id="hotel-change-reason" name="reason" required minLength={3} maxLength={500}
              value={reason} onChange={event => { setReason(event.target.value); clearIssue('reason'); }}
              placeholder="For example: added hotel directions and review page"
              aria-invalid={Boolean(errorFor('reason'))} aria-describedby={`hotel-reason-help${errorFor('reason') ? ' hotel-reason-error' : ''}`}/>
            <small id="hotel-reason-help">A short note recorded in your hotel’s settings history.</small>
            {errorFor('reason') && <small id="hotel-reason-error" className="hotel-information-field-error" role="alert">{errorFor('reason')}</small>}
          </label>
        </fieldset>
        {state.error && !state.fieldErrors && <p className="hotel-information-notice error" role="alert">{state.error}</p>}
        {state.success && <p className="hotel-information-notice" role="status">{state.success}</p>}
        <button className="dash-button" disabled={pending}>{pending ? 'Saving…' : 'Save hotel links'}</button>
      </form>
    </section>
    <section className="sr-panel"><HotelPhotoLibrary pid={pid} initialPhotos={resources.photos} manage/></section>
    <div className="settings-template-actions">
      <Link href={`/p/${pid}/automations?tab=templates`}>Create or manage WhatsApp templates →</Link>
      <Link href={`/p/${pid}/automations?tab=menu`}>Configure guest menu →</Link>
    </div>
  </div>;
}

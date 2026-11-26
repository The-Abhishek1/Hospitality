'use client';
import {useRef, useState} from 'react';
import Link from 'next/link';
import type {HotelDeletionPreview} from '@/lib/hotel-deletion';

export function DeleteHotel({preview}: {preview: HotelDeletionPreview}) {
  return <DeletionConfirmation preview={preview} kind="hotel"/>;
}
export function DeleteBusiness({preview}: {preview: HotelDeletionPreview}) {
  return <DeletionConfirmation preview={preview} kind="business"/>;
}
function DeletionConfirmation({preview, kind}: {preview: HotelDeletionPreview; kind: 'hotel' | 'business'}) {
  const business = kind === 'business';
  const back = business ? `/admin?view=businesses` : `/admin/businesses/${preview.tenant}`;
  const [job, setJob] = useState(preview.job);
  const [complete, setComplete] = useState(preview.state === 'complete');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [progress, setProgress] = useState('');
  const [name, setName] = useState('');
  const [reason, setReason] = useState('');
  const [password, setPassword] = useState('');
  const [acknowledged, setAcknowledged] = useState(false);
  const running = useRef(false);
  const requestId = useRef<string | null>(null);
  const blocked = Boolean(preview.blockers?.length);
  const valid = name === preview.name && reason.trim().length >= 5 && password.length > 0 && acknowledged;
  async function run() {
    if (running.current) return;
    running.current = true; setBusy(true); setError('');
    try {
      let current = job;
      const call = async (body: object) => {
        const response = await fetch(`/api/admin/${business ? 'businesses' : 'hotels'}/${preview.id}/delete`, {
          method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body),
        });
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || `Could not complete ${kind} deletion.`);
        return data;
      };
      if (!current) {
        requestId.current ||= crypto.randomUUID();
        setProgress(`Verifying your confirmation and stopping ${kind} activity…`);
        const started = await call({action: 'begin', request: requestId.current, version: preview.version, name, reason, password, acknowledged});
        current = started.job; setJob(current); setPassword('');
      }
      for (;;) {
        const result = await call({action: 'continue', job: current});
        if (result.state === 'complete') { setComplete(true); setProgress(''); break; }
        setProgress(result.state === 'hotels' ? `${result.completed} of ${result.total} hotels removed. Keep this page open.` : `Removing uploaded files${result.hotel ? ` for ${result.hotel}` : ''}… ${result.remaining} remaining. Keep this page open.`);
      }
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Deletion was interrupted. Refresh to check its status.');
    } finally { running.current = false; setBusy(false); }
  }
  if (complete) return <section className="pa-panel" role="status"><h2>{business ? 'Business permanently deleted' : 'Hotel permanently deleted'}</h2><p>{preview.name} {business ? 'and all its hotels and business data have been removed. Other businesses and login accounts remain available.' : 'and its hotel data have been removed. The business account and other hotels remain available.'}</p><Link className="pa-button" href={back}>{business ? 'Return to business accounts →' : 'Return to business account →'}</Link></section>;
  return <section className="pa-panel pa-delete-hotel">
    {job ? <><h2>Finish permanent deletion</h2><p>{business ? 'This business and all its hotels are frozen.' : 'This hotel is frozen and its saved integration credentials have been removed.'} Resume to finish removing files and records. You can return to this page if cleanup is interrupted.</p></> : <>
      <h2>Confirm permanent deletion</h2>
      <p>{business ? 'This permanently removes the business, every hotel it owns, guest profiles, team memberships, invitations, custom roles and subscription records. All hotel reservations, bills, documents, photos, rooms, orders, services, WhatsApp history, automation and saved credentials are included.' : 'This permanently removes reservations, bills, documents, uploaded photos, rooms, orders, tasks, services, WhatsApp conversations, saved templates, automation, campaigns and connection credentials from Hospitality.'}</p>
      <p>{business ? 'Owner and staff login accounts remain available, including access to other businesses. Access to this business is removed. A minimal platform deletion receipt is retained.' : 'Guest profiles used only by this hotel are removed. Shared guest profiles, login accounts, the business account and other hotels are preserved. A minimal platform deletion receipt is retained.'}</p>
      <p>External Meta accounts and templates, WhatsApp phone registrations, OTA listings and Razorpay accounts or transactions remain with their providers. Close sales and resolve payments there before deleting.</p>
      {blocked && <div className="pa-alert error" role="alert"><strong>Resolve these items first</strong><ul>{preview.blockers?.map(item => <li key={item}>{item}</li>)}</ul><p>Refresh this page after they are resolved.</p></div>}
      <div className="pa-form">
        <label>Reason<textarea value={reason} onChange={e => setReason(e.target.value)} minLength={5} maxLength={1000} disabled={busy} placeholder="For example, the owner requested permanent removal."/></label>
        <label><span>Type <strong>{preview.name}</strong> to confirm</span><input value={name} onChange={e => setName(e.target.value)} autoComplete="off" disabled={busy}/></label>
        <label>Your platform admin password<input type="password" autoComplete="current-password" value={password} onChange={e => setPassword(e.target.value)} disabled={busy}/></label>
        <label className="pa-delete-ack"><input type="checkbox" checked={acknowledged} onChange={e => setAcknowledged(e.target.checked)} disabled={busy}/><span>I understand this permanently deletes {business ? 'the business and every hotel it owns' : 'the hotel’s data'}, including active and historical stays and financial records. I have saved any required exports and handled its external sales and payments.</span></label>
      </div>
    </>}
    {progress && <p role="status" aria-live="polite">{progress}</p>}
    {error && <p role="alert" className="pa-alert error">{error}{job && ` The ${kind} remains frozen. Use Resume deletion to retry.`}</p>}
    <div className="pa-actions"><button type="button" className="pa-button pa-danger" disabled={busy || (!job && (!valid || blocked))} onClick={run}>{busy ? `Deleting ${kind}…` : job ? 'Resume deletion' : `Delete ${kind} permanently`}</button>{!job && <Link href={back}>Cancel</Link>}</div>
  </section>;
}

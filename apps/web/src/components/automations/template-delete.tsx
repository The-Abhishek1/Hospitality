'use client';
import { useEffect, useId, useRef, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
type Context = { name: string; language: string; status: string; provider_id: string; deleted: boolean; can_delete: boolean; blockers: string[]; usage: { events: string[]; services: number; campaigns: number; messages: number; shared_hotels: number } };
export function TemplateDelete({ pid, template, name }: { pid: string; template: string; name: string }) {
  const dialog = useRef<HTMLDialogElement>(null), title = useId(), router = useRouter();
  const [context, setContext] = useState<Context | null>(null), [busy, setBusy] = useState(false), [error, setError] = useState(''), [confirm, setConfirm] = useState(''), [deleted, setDeleted] = useState(false);
  const endpoint = `/api/whatsapp/${pid}/templates/${template}`;
  useEffect(() => { if (deleted) router.refresh(); }, [deleted, router]);
  async function open() {
    setContext(null); setError(''); setConfirm(''); setBusy(true); dialog.current?.showModal();
    try {
      const response = await fetch(endpoint, { cache: 'no-store', signal: AbortSignal.timeout(20000) }), data = await response.json();
      if (!response.ok) throw Error(data.error ?? 'Could not load template usage.');
      setContext(data);
    } catch (e) { setError(e instanceof Error ? e.message : 'Could not load template usage.'); }
    finally { setBusy(false); }
  }
  async function remove(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!context?.can_delete || confirm !== context.name || busy) return;
    setBusy(true); setError('');
    let responded = false;
    try {
      const response = await fetch(endpoint, { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ provider_id: context.provider_id, confirm_name: confirm, confirm_language: context.language }), signal: AbortSignal.timeout(55000) }), data = await response.json();
      responded = true;
      if (!response.ok || !data.deleted) { if (data.uncertain) setContext(current => current ? { ...current, can_delete: false } : null); throw Error(data.error ?? 'Could not delete template.'); }
      dialog.current?.close(); setDeleted(true);
    } catch (e) { if (!responded) setContext(current => current ? { ...current, can_delete: false } : null); setError(responded && e instanceof Error ? e.message : 'Deletion could not be confirmed. Check approval & sync before retrying.'); }
    finally { setBusy(false); }
  }
  if (deleted) return <p className="auto-help" role="status">Template deleted from Meta. Updating library…</p>;
  return <>
    <button type="button" className="dash-button auto-delete-button" aria-label={`Delete template ${name}`} onClick={open}>Delete template</button>
    <dialog ref={dialog} className="auto-delete-dialog" aria-labelledby={title} onCancel={event => { if (busy) event.preventDefault(); }}>
      <div className="auto-delete-heading"><h3 id={title}>Delete WhatsApp template</h3><button type="button" className="dash-button dash-secondary" aria-label="Close delete confirmation" disabled={busy} onClick={() => dialog.current?.close()}>×</button></div>
      <p>This permanently deletes the selected template and language from your hotel’s Meta account. Other translations and message history are retained. Messages already sent are not recalled.</p>
      {busy && !context && <p role="status">Checking template usage…</p>}
      {context && <>
        <dl className="auto-delete-details"><div><dt>Template</dt><dd>{context.name}</dd></div><div><dt>Language</dt><dd>{context.language}</dd></div><div><dt>Meta status</dt><dd>{context.status}</dd></div></dl>
        <p className="auto-help">Meta prevents reuse of a deleted approved template’s name for 30 days. To replace its wording, use a new name such as {context.name}_v2.</p>
        {!!context.blockers.length && <div className="auto-notice error"><strong>Before deleting</strong><ul>{context.blockers.map(reason => <li key={reason}>{reason}</li>)}</ul></div>}
        {!!context.usage.events.length && <div className="auto-delete-links">{context.usage.events.map(event => <Link key={event} href={`/p/${pid}/whatsapp?tab=rules&event=${event}`}>Review {event.replaceAll('_', ' ')} →</Link>)}</div>}
        {context.usage.services > 0 && <Link href={`/p/${pid}/whatsapp?tab=menu`}>Review {context.usage.services} active menu service(s) →</Link>}
        {context.usage.campaigns > 0 && <Link href={`/p/${pid}/campaigns`}>Review active campaigns →</Link>}
        {context.usage.messages > 0 && <Link href={`/p/${pid}/inbox`}>Review message deliveries →</Link>}
        {context.deleted && <p role="status">This template is already deleted. Refresh the library.</p>}
      </>}
      {error && <p className="auto-notice error" role="alert">{error}</p>}
      <form onSubmit={remove}>
        {context?.can_delete && <label>Type {context.name} to confirm<input value={confirm} onChange={event => setConfirm(event.target.value)} autoComplete="off" spellCheck={false} disabled={busy} required/></label>}
        <div className="auto-template-actions"><button type="button" className="dash-button dash-secondary" disabled={busy} onClick={() => dialog.current?.close()}>Cancel</button>{context?.can_delete && <button className="dash-button auto-delete-button" disabled={busy || confirm !== context.name}>{busy ? 'Deleting from Meta…' : 'Permanently delete template'}</button>}</div>
      </form>
    </dialog>
  </>;
}

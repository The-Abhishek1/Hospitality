// Imported app data must never run live guest commands, grant consent, or open a reply window.
export function number(value) { return typeof value === 'string' ? value.replace(/[\s()+.-]/g, '') : ''; }
function timestamp(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 && n < 1e11 ? new Date(n * 1000).toISOString() : null;
}
function contactKey(phone, user) { return /^[1-9]\d{6,14}$/.test(phone) ? `phone:${phone}` : typeof user === 'string' && user.length <= 150 ? `user:${user}` : null; }
function message(m, phone, source, direction) {
  const sent_at = timestamp(m?.timestamp);
  if (!m || typeof m.id !== 'string' || !m.id || m.id.length > 300 || !sent_at || !['in', 'out'].includes(direction)) return null;
  const type = typeof m.type === 'string' ? m.type.slice(0, 40) : 'unknown';
  const body = type === 'text' ? m.text?.body : m[type]?.caption;
  return { kind: 'message', id: m.id, phone: /^[1-9]\d{6,14}$/.test(phone) ? phone : null,
    user_id: m.to_user_id ?? m.from_user_id ?? null, source, direction, type, sent_at,
    body: typeof body === 'string' ? body.slice(0, 4096) : `[${type}]`,
    status: ['sent', 'delivered', 'read'].includes(m.history_context?.status) ? m.history_context.status : 'sent' };
}
export function coexistenceBatch(field, payload, offset = 0, limit = 200) {
  if (!Number.isInteger(offset) || offset < 0 || !Number.isInteger(limit) || limit < 1 || limit > 200) throw Error('Invalid batch cursor');
  const records = [], summary = { progress: 0, declined: false, error: false };
  if (field === 'smb_app_state_sync') {
    for (const item of payload.state_sync ?? []) {
      if (item.type !== 'contact' || !['add', 'remove'].includes(item.action)) continue;
      const c = item.contact ?? {}, phone = number(c.phone_number), key = contactKey(phone, c.user_id), sent_at = timestamp(item.metadata?.timestamp);
      if (!key || !sent_at) continue;
      records.push({ kind: 'contact', contact_key: key, phone: /^[1-9]\d{6,14}$/.test(phone) ? phone : null,
        name: typeof c.full_name === 'string' ? c.full_name.slice(0, 200) : typeof c.first_name === 'string' ? c.first_name.slice(0, 200) : '',
        removed: item.action === 'remove', sent_at });
    }
  } else if (field === 'smb_message_echoes') {
    for (const m of payload.message_echoes ?? []) {
      const record = message(m, number(m.to), 'business_app', 'out');
      if (record) records.push(record);
    }
  } else if (field === 'history') {
    const business = number(payload.metadata?.display_phone_number);
    for (const chunk of payload.history ?? []) {
      summary.declined ||= chunk.errors?.some(e => e.code === 2593109) ?? false;
      summary.error ||= chunk.errors?.some(e => e.code !== 2593109) ?? false;
      if (Number.isInteger(chunk.metadata?.progress)) summary.progress = Math.max(summary.progress, Math.min(100, Math.max(0, chunk.metadata.progress)));
      for (const thread of chunk.threads ?? []) {
        const phone = number(thread.context?.wa_id ?? thread.id);
        for (const m of thread.messages ?? []) {
          // Do not guess direction for phone-less contacts; keep a support record instead.
          const from = number(m.from), direction = m.to || (business && from === business) ? 'out' : from && phone && from === phone || m.from_user_id ? 'in' : null;
          const record = message(m, direction ? phone : '', 'history', direction ?? 'in');
          if (record) records.push(record);
        }
      }
    }
  } else throw Error('Unsupported coexistence event');
  if (offset > records.length) throw Error('Invalid batch cursor');
  return { records: records.slice(offset, offset + limit), next: Math.min(records.length, offset + limit), done: offset + limit >= records.length, summary };
}

// SMB sync endpoints are single-use. An ambiguous response is not safe to retry.
export async function requestCoexistenceSync({phone, kind, token, version = 'v27.0'}, fetcher = fetch) {
  if (!/^\d{5,30}$/.test(phone ?? '') || !['smb_app_state_sync', 'history'].includes(kind)) throw Error('Invalid sync job');
  try {
    const r = await fetcher(`https://graph.facebook.com/${version}/${phone}/smb_app_data`, {
      method: 'POST', signal: AbortSignal.timeout(20000), headers: {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'},
      body: JSON.stringify({messaging_product: 'whatsapp', sync_type: kind}) });
    if (!r.ok) return {state: r.status >= 500 || r.status === 408 || r.status === 409 ? 'unknown' : 'failed'};
    const d = await r.json();
    return typeof d.request_id === 'string' && d.request_id.length <= 200 ? {state: 'requested', request: d.request_id} : {state: 'unknown'};
  } catch { return {state: 'unknown'}; }
}

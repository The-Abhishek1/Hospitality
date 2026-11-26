export type HotelDeletionPreview = {
  id: string; tenant: string; name: string; version?: number;
  state: 'review' | 'files' | 'complete'; job?: string;
  counts: Record<string, number>; files_remaining: number; blockers?: string[];
};
export function deletionGroups(counts: Record<string, number>) {
  const sum = (...keys: string[]) => keys.reduce((n, key) => n + (counts[key] || 0), 0);
  return [
    ['Reservations', sum('reservations')],
    ['Rooms', sum('accommodation_units')],
    ['Bills & payments', sum('folios', 'invoices', 'credit_notes', 'payments', 'refunds')],
    ['Food orders & service requests', sum('orders', 'guest_requests')],
    ['WhatsApp conversations & messages', sum('conversations', 'messages')],
    ['Templates, event rules & campaigns', sum('message_templates', 'whatsapp_template_drafts', 'whatsapp_automation_rules', 'whatsapp_campaigns')],
    ['Guest identity documents', sum('guest_documents')],
  ] as const;
}

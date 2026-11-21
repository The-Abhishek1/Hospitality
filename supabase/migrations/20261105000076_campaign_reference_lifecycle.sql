-- Template deletion preserves message text/history but removes sending eligibility.
-- Tenant teardown must not depend on cascade trigger order.
alter table public.messages drop constraint messages_template_id_fkey;
alter table public.messages add constraint messages_template_id_fkey foreign key(template_id)references public.message_templates(id)on delete set null;
alter table public.whatsapp_campaigns drop constraint whatsapp_campaigns_template_id_fkey;
alter table public.whatsapp_campaigns add constraint whatsapp_campaigns_template_id_fkey foreign key(template_id)references public.message_templates(id)on delete set null;
-- Campaigns have no client delete API. A trusted permanent deletion removes its queued/delivered rows,
-- rather than turning campaign messages into ordinary inbox sends when the campaign reference disappears.
alter table public.messages drop constraint messages_campaign_id_fkey;
alter table public.messages add constraint messages_campaign_id_fkey foreign key(campaign_id)references public.whatsapp_campaigns(id)on delete cascade;

-- Structural guards that catch the classic mistakes: a table without RLS, a function open to the wrong role,
-- a SECURITY DEFINER function with a mutable search_path. Runs against whatever migrations exist.
begin;
select plan(6);

select is_empty(
  $$select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity$$,
  'every public table has row level security enabled');

select is_empty(
  $$select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private') and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')$$,
  'every SECURITY DEFINER function pins its search_path');

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and has_function_privilege('anon', p.oid, 'execute')),
  array['portal_command', 'portal_create_request', 'portal_get_stay', 'portal_place_order', 'portal_submit_feedback', 'portal_workspace'],
  'anon can execute only the token-scoped portal functions');

select is_empty(
  $$select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and has_function_privilege('anon', p.oid, 'execute')$$,
  'anon cannot execute anything in the private schema');

select is_empty(
  $$select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'ingest_whatsapp_inbound', 'ingest_whatsapp_status', 'claim_outbound_messages', 'complete_outbound_message',
      'portal_prepare_document', 'portal_confirm_document', 'mark_document_scan',
      'ingest_channel_event', 'process_pending_channel_events', 'claim_sync_jobs', 'complete_sync_job',
      'channel_availability_range', 'mock_provider_push', 'mock_reconcile', 'mock_ota_emit', 'mock_ota_poll')
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))$$,
  'service-role-only functions are not callable by clients');

select is_empty(
  $$select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
      and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'portal\_%'$$,
  'no SECURITY DEFINER function outside the portal is open to anon');

select * from finish();
rollback;

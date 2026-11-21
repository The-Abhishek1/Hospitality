-- Keep older clients on the same authorization and conversation-state rules.
create or replace function public.send_whatsapp_message(p_conversation uuid,p_body text default null,p_template uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
begin return public.inbox_send(p_conversation,pg_catalog.gen_random_uuid(),p_body,p_template);end $$;
create or replace function public.claim_conversation(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare c public.conversations;
begin c:=private.lock_conversation(p_id,'whatsapp.use');perform public.inbox_manage(c.id,c.version,'claim');end $$;
create or replace function public.assign_conversation(p_id uuid,p_user uuid) returns void
language plpgsql security definer set search_path='' as $$
declare c public.conversations;
begin c:=private.lock_conversation(p_id,'whatsapp.use');perform public.inbox_manage(c.id,c.version,'assign',p_user);end $$;
create or replace function public.set_conversation_handoff(p_id uuid,p_human boolean) returns void
language plpgsql security definer set search_path='' as $$
declare c public.conversations;
begin c:=private.lock_conversation(p_id,'whatsapp.use');perform public.inbox_manage(c.id,c.version,case when p_human then 'human_on' else 'human_off' end);end $$;
create or replace function public.close_conversation(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare c public.conversations;
begin c:=private.lock_conversation(p_id,'whatsapp.use');perform public.inbox_manage(c.id,c.version,'close');end $$;

-- Root menu greetings always use this conversation's current hotel name,
-- including existing saved menus and future property renames.
create function private.whatsapp_menu_intro(p_property uuid)returns text
language sql stable security definer set search_path=''as $$
 select 'Welcome to '||left(regexp_replace(trim(name),'[[:space:]]+',' ','g'),400)||'. How can we help with your stay?'from public.properties where id=p_property
$$;
revoke all on function private.whatsapp_menu_intro(uuid)from public,anon,authenticated,service_role;
do $$declare signature text;definition text;begin
 foreach signature in array array['private.queue_whatsapp_guest_reply_flat(uuid,uuid,text,boolean,uuid,text)','private.queue_whatsapp_guest_reply_before_journey(uuid,uuid,text,boolean,uuid,text)']loop
  definition:=pg_get_functiondef(signature::regprocedure);
  if strpos(definition,'cfg.data->>''intro''')=0 then raise exception 'Unexpected guest menu greeting definition: %',signature;end if;
  execute replace(definition,'cfg.data->>''intro''','private.whatsapp_menu_intro(c.property_id)');
 end loop;
end $$;

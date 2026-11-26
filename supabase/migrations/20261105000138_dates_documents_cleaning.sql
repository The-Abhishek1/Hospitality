-- Display dates without changing canonical ISO API/storage values.
create function private.whatsapp_display_text(p_text text)returns text language sql immutable set search_path=''as $$
 select regexp_replace(regexp_replace(regexp_replace(p_text,'\mArrival\M','Check-in','g'),'\mDeparture\M','Check-out','g'),'\m([0-9]{4})-([0-9]{2})-([0-9]{2})\M','\3-\2-\1','g')
$$;
revoke all on function private.whatsapp_display_text(text)from public,anon,authenticated;
alter table public.guest_documents drop constraint guest_documents_doc_type_check;
alter table public.guest_documents add constraint guest_documents_doc_type_check check(doc_type in('id_proof','passport','visa','aadhaar','pan','other'));
alter table public.property_settings drop constraint property_settings_cleaning_checklist_check;
alter table public.property_settings add constraint property_settings_cleaning_checklist_check check(jsonb_typeof(cleaning_checklist)='array'and jsonb_array_length(cleaning_checklist)<=200);
-- Keep all admission, preparation and progress counts consistent for these identity types.
do $$declare f record;d text;begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','private')and p.prosrc like '%''id_proof''%''passport''%''visa''%'loop
  d:=pg_get_functiondef(f.oid);d:=replace(d,'''id_proof'',''passport'',''visa''','''id_proof'',''passport'',''visa'',''aadhaar'',''pan''');d:=replace(d,'''id_proof'', ''passport'', ''visa''','''id_proof'', ''passport'', ''visa'', ''aadhaar'', ''pan''');execute d;
 end loop;
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','private')and p.proname in('property_settings_save','task_create_advanced','task_action')loop
  d:=pg_get_functiondef(f.oid);d:=replace(replace(replace(replace(d,'>20','>200'),'>=20','>=200'),'20 checklist','200 checklist'),'20 items','200 items');execute d;
 end loop;
 -- The notification payload retains ISO dates for schedule validation. Only render variables change.
 d:=pg_get_functiondef('public.dispatch_whatsapp_automations(integer,text)'::regprocedure);
 d:=replace(d,'params:=''[]'';body:=t.body;why:=null;', 'vars:=vars||jsonb_build_object(''check_in'',to_char(r.check_in,''DD-MM-YYYY''),''check_out'',to_char(r.check_out,''DD-MM-YYYY''));params:=''[]'';body:=t.body;why:=null;');execute d;
 -- Native replies use the same convention, including interactive message bodies.
 d:=pg_get_functiondef('private.queue_journey_reply(uuid,uuid,text,text,jsonb,uuid)'::regprocedure);
 d:=replace(d,'begin',E'begin\n p_body:=private.whatsapp_display_text(p_body);\n if p_payload#>>''{interactive,body,text}''is not null then p_payload:=jsonb_set(p_payload,''{interactive,body,text}'',to_jsonb(private.whatsapp_display_text(p_payload#>>''{interactive,body,text}'')));end if;');execute d;
end $$;

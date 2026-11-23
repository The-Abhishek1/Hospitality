-- The public helper exposes only the hotel's connected sender, never a credential or phone-number ID.
alter function public.portal_workspace(text,jsonb)rename to portal_workspace_before_journey;
revoke all on function public.portal_workspace_before_journey(text,jsonb)from public,anon,authenticated,service_role;
create function public.portal_workspace(p_token text,p_filters jsonb default '{}')returns jsonb
language plpgsql security definer set search_path=''as $$
declare data jsonb;r public.reservations;s public.whatsapp_journey_settings;phone text;
begin
 data:=public.portal_workspace_before_journey(p_token,p_filters);
 r:=private.portal_reservation(p_token);
 select *into s from public.whatsapp_journey_settings where property_id=r.property_id;
 select regexp_replace(display_phone,'[^0-9]','','g')into phone from public.whatsapp_connections where property_id=r.property_id and status='active';
 if phone!~'^[1-9][0-9]{7,14}$'then phone:=null;end if;
 return data||jsonb_build_object('journey',jsonb_build_object('enabled',coalesce(s.enabled,false),'sender',phone,'required_documents',coalesce(s.required_documents,1)));
end $$;
revoke all on function public.portal_workspace(text,jsonb)from public,anon,authenticated;
grant execute on function public.portal_workspace(text,jsonb)to anon,authenticated;

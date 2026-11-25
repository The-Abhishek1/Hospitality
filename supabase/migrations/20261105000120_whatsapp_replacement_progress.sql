alter function public.whatsapp_default_workspace(uuid)rename to whatsapp_default_workspace_before_replacements;
revoke all on function public.whatsapp_default_workspace_before_replacements(uuid)from public,anon,authenticated,service_role;
create function public.whatsapp_default_workspace(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$declare result jsonb;begin
 result:=public.whatsapp_default_workspace_before_replacements(p_property);
 return result||jsonb_build_object('replacements',coalesce((select jsonb_agg(x order by created_at desc)from(select id,old_template,new_name,state,last_error,created_at,applied_at from public.whatsapp_template_replacements where property_id=p_property order by created_at desc limit 30)x),'[]'::jsonb));
end $$;
revoke all on function public.whatsapp_default_workspace(uuid)from public,anon;grant execute on function public.whatsapp_default_workspace(uuid)to authenticated;

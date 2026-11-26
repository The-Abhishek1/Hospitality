-- Retain historical connection IDs; only an active sender owns webhook routing.
alter table public.whatsapp_connections drop constraint whatsapp_connections_phone_number_id_key;
create unique index whatsapp_active_phone_unique on public.whatsapp_connections(phone_number_id)where status='active';
create function public.whatsapp_transfer_choices(p_property uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
begin
 perform public.whatsapp_setup_context(p_property);
 return coalesce((select jsonb_agg(jsonb_build_object('property',p.id,'name',p.name,'connection',c.id,'phone',c.display_phone)order by p.name)from public.whatsapp_connections c join public.properties p on p.id=c.property_id join private.whatsapp_credentials k on k.property_id=p.id where p.id<>p_property and c.status='active'and private.has_permission(p.id,'staff.manage')),'[]'::jsonb);
end $$;
create function public.whatsapp_transfer_context(p_property uuid,p_source uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare c public.whatsapp_connections;
begin
 perform public.whatsapp_setup_context(p_property);perform public.whatsapp_setup_context(p_source);
 if p_source=p_property or exists(select 1 from public.whatsapp_connections where property_id=p_property)then raise exception 'Choose a new hotel without an existing connection.'using errcode='22023';end if;
 select *into c from public.whatsapp_connections where property_id=p_source and status='active';
 if c.id is null or not exists(select 1 from private.whatsapp_credentials where property_id=p_source)then raise exception 'Reconnect the old hotel with Meta before moving its number.'using errcode='22023';end if;
 return jsonb_build_object('id',c.id,'phone',c.phone_number_id,'waba',c.waba_id,'display',c.display_phone,'mode',c.connection_mode);
end $$;
create function public.whatsapp_transfer_commit(p_property uuid,p_source uuid,p_actor uuid,p_connection uuid,p_ciphertext text)returns uuid language plpgsql security definer set search_path=''as $$
declare c public.whatsapp_connections;cid uuid;tenant uuid;
begin
 perform private.staff_share(p_property);perform private.staff_share(p_source);
 if p_property=p_source or not private.whatsapp_actor_allowed(p_property,p_actor)or not private.whatsapp_actor_allowed(p_source,p_actor)then raise exception 'Administrator access to both hotels is required.'using errcode='42501';end if;
 if p_ciphertext is null or length(p_ciphertext)not between 40 and 20000 then raise exception 'Verified credentials required.'using errcode='22023';end if;
 perform 1 from public.properties where id in(p_source,p_property)order by id for update;
 select *into c from public.whatsapp_connections where property_id=p_source and id=p_connection and status='active'for update;
 if c.id is null or exists(select 1 from public.whatsapp_connections where property_id=p_property)then raise exception 'Connection changed. Refresh and review both hotels.'using errcode='40001';end if;
 if not exists(select 1 from private.whatsapp_credentials where property_id=p_source)then raise exception 'Reconnect the source hotel with Meta first.'using errcode='22023';end if;
 perform 1 from public.messages where property_id=p_source and direction='out'and(status in('queued','sending')or delivery_uncertain)order by id for update;
 if exists(select 1 from public.messages where property_id=p_source and direction='out'and(status='sending'or delivery_uncertain))then raise exception 'A message is sending or its delivery is uncertain. Resolve delivery before moving this number.'using errcode='22023';end if;
 if exists(select 1 from public.whatsapp_default_setup where property_id=p_source and lease is not null and locked_at>now()-interval '5 minutes')then raise exception 'Template setup is running. Wait for it to finish before moving this number.'using errcode='22023';end if;
 update public.whatsapp_default_setup set enabled=false,lease=null,locked_at=null,version=version+1,updated_at=now()where property_id=p_source;
 update public.whatsapp_connections set status='disabled'where id=c.id;
 delete from private.whatsapp_credentials where property_id=p_source;
 update private.whatsapp_setup_sessions set consumed=true where property_id in(p_source,p_property);
 update public.messages set status='failed',error='Sender moved to another hotel. This old-hotel message will not be sent.',locked_at=null where property_id=p_source and direction='out'and status='queued';
 update public.whatsapp_automation_rules set enabled=false,version=version+1,updated_at=now()where property_id=p_source and enabled;
 update public.whatsapp_automation_events set state='skipped',reason='Sender moved to another hotel.'where property_id=p_source and state in('pending','blocked','queued');
 update public.whatsapp_campaigns set status='cancelled'where property_id=p_source and status in('draft','scheduled','running','blocked');
 select tenant_id into tenant from public.properties where id=p_property;
 insert into public.whatsapp_connections(tenant_id,property_id,phone_number_id,waba_id,display_phone,credentials_ref,status,connection_mode)values(tenant,p_property,c.phone_number_id,c.waba_id,c.display_phone,'managed:'||p_property,'active',c.connection_mode)returning id into cid;
 insert into private.whatsapp_credentials(property_id,credentials_ref,ciphertext)values(p_property,'managed:'||p_property,p_ciphertext);
 insert into public.whatsapp_connection_audit(property_id,actor,action)values(p_source,p_actor,'number_moved_out'),(p_property,p_actor,'number_moved_in');
 -- No conversations, guests, consent, templates or imported history are copied.
 return cid;
end $$;
revoke all on function public.whatsapp_transfer_choices(uuid),public.whatsapp_transfer_context(uuid,uuid),public.whatsapp_transfer_commit(uuid,uuid,uuid,uuid,text)from public,anon,authenticated;
grant execute on function public.whatsapp_transfer_choices(uuid),public.whatsapp_transfer_context(uuid,uuid)to authenticated;
grant execute on function public.whatsapp_transfer_commit(uuid,uuid,uuid,uuid,text)to service_role;
notify pgrst,'reload schema';

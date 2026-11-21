create function public.whatsapp_campaign_report(p_property uuid,p_campaign uuid,p_page int default 1)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare c public.whatsapp_campaigns;report jsonb;
begin
 if not private.has_permission(p_property,'staff.manage')then raise exception 'not permitted'using errcode='42501';end if;
 select *into c from public.whatsapp_campaigns where id=p_campaign and property_id=p_property;
 if not found then raise exception 'Campaign not found.'using errcode='P0002';end if;
 if c.status='draft'then
 with audience as materialized(select *from private.campaign_audience(p_property,c.filters,case when c.selection_mode='selected'then c.selected_guests else null end))
 select jsonb_build_object('total',(select count(*)from audience),'eligible',(select count(*)from audience where exclusion is null),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from audience order by guest_name,guest_id limit 30 offset(greatest(1,least(p_page,10000))-1)*30)x),'[]'::jsonb))into report;
 else
 with recipients as materialized(select r.id,r.guest_name,r.wa_contact_id as phone,case when r.state='pending'then'pending'when r.state='skipped'then'skipped'else coalesce(m.status,'unknown')end as state,coalesce(r.skip_reason,m.error)as reason from public.whatsapp_campaign_recipients r left join public.messages m on m.id=r.message_id where r.campaign_id=c.id)
 select jsonb_build_object('total',(select count(*)from recipients),'counts',coalesce((select jsonb_object_agg(state,n)from(select state,count(*)n from recipients group by state)t),'{}'::jsonb),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from recipients order by guest_name,id limit 30 offset(greatest(1,least(p_page,10000))-1)*30)x),'[]'::jsonb))into report;
 end if;
 return jsonb_build_object('campaign',to_jsonb(c),'audience',report,'timezone',(select timezone from public.properties where id=p_property));
end $$;
revoke all on function public.whatsapp_campaign_report(uuid,uuid,int)from public,anon;
grant execute on function public.whatsapp_campaign_report(uuid,uuid,int)to authenticated;

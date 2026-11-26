-- Reuse the existing private-stay delivery guard for the confirmation's document
-- link, so a later phone/profile correction invalidates an undelivered reply.
do $$declare d text;needle text:='perform private.queue_journey_reply(c.id,p_source,''enquiry_confirmed'',body,null);';begin
 d:=pg_get_functiondef('private.handle_whatsapp_journey(uuid,uuid,text,text)'::regprocedure);
 if strpos(d,needle)=0 then raise exception 'Unexpected booking confirmation definition.';end if;
 execute replace(d,needle,'perform private.queue_journey_reply(c.id,p_source,''enquiry_confirmed'',body,null,rid);');
end $$;

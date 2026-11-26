-- A test payment must never become a real receipt by switching merchant modes.
do $$declare d text;needle text:='if exists(select 1 from public.hotel_payment_requests where property_id=p_property and state in';begin
 d:=pg_get_functiondef('public.payment_connection_commit(uuid,uuid,uuid,text,text,boolean)'::regprocedure);
 if strpos(d,needle)=0 then raise exception 'Payment connection definition changed.';end if;
 d:=replace(d,needle,E'if exists(select 1 from public.payments pay join public.hotel_payment_requests req on req.id=pay.online_request_id join public.hotel_payment_connections c on c.id=req.connection_id where req.property_id=p_property and c.mode<>case when p_key_hint like ''rzp_live_%''then''live''else''test''end)then raise exception ''This hotel has recorded payments in the other mode. Use a separate hotel for Test Mode so synthetic and real receipts stay separate.''using errcode=''22023'';end if;\n '||needle);execute d;
end $$;

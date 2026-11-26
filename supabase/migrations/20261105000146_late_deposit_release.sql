-- A capture arriving after the deadline can race the minute-based expiry job.
-- Account for the money but release the provisional room in this transaction.
do $$declare d text;needle text:=E'else\n  update public.hotel_payment_requests set last_error=';begin
 d:=pg_get_functiondef('private.finish_whatsapp_deposit(uuid)'::regprocedure);
 if strpos(d,needle)=0 then raise exception 'Deposit finalization definition changed.';end if;
 d:=replace(d,needle,E'else\n  if r.status=''pending_payment''then\n   update public.reservations set status=''cancelled'',notes=left(coalesce(notes,'''')||E''\\nDeposit received after the hold ended; staff review required.'',2000)where id=r.id;\n   update public.unit_holds set active=false where reservation_id=r.id and active;\n   update private.whatsapp_booking_sessions set step=''cancelled'',version=version+1 where reservation_id=r.id;\n  end if;\n  update public.hotel_payment_requests set last_error=');execute d;
end $$;

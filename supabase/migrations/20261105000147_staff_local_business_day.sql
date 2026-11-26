-- Attendance must use the same hotel-local day shown in the attendance form.
do $$declare d text;begin
 d:=pg_get_functiondef('public.staff_manage(uuid,uuid,text,jsonb)'::regprocedure);
 d:=replace(d,'declare cmd private.staff_commands;','declare hotel_day date;cmd private.staff_commands;');
 d:=replace(d,'if p_request is null',E'select (now()at time zone timezone)::date into hotel_day from public.properties where id=p_property;\n if p_request is null');
 d:=replace(d,'current_date','hotel_day');execute d;
end $$;

-- Only the application backend can query auth account state; no public email directory.
create table private.signup_attempts(bucket text primary key,window_start timestamptz not null,hits integer not null);
revoke all on private.signup_attempts from public,anon,authenticated,service_role;
create function public.signup_account_check(p_email text,p_address_hash text)returns text language plpgsql security definer set search_path=''as $$
declare bucket_key text;n integer;state text;
begin
 if length(p_email)>254 or p_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'or p_address_hash!~'^[a-f0-9]{64}$'then raise exception 'Invalid signup request.'using errcode='22023';end if;
 foreach bucket_key in array array['ip:'||p_address_hash,'email:'||encode(sha256(convert_to(lower(trim(p_email)),'utf8')),'hex')]loop
  insert into private.signup_attempts values(bucket_key,clock_timestamp(),1)on conflict(bucket)do update set hits=case when signup_attempts.window_start<clock_timestamp()-interval '10 minutes'then 1 else signup_attempts.hits+1 end,window_start=case when signup_attempts.window_start<clock_timestamp()-interval '10 minutes'then clock_timestamp()else signup_attempts.window_start end returning hits into n;
  if n>(case when bucket_key like'ip:%'then 30 else 6 end)then return 'limited';end if;
 end loop;
 delete from private.signup_attempts where window_start<now()-interval '1 day';
 select case when email_confirmed_at is null then'pending'else'exists'end into state from auth.users where lower(email)=lower(trim(p_email))and deleted_at is null limit 1;
 return coalesce(state,'new');
end $$;
revoke all on function public.signup_account_check(text,text)from public,anon,authenticated;
grant execute on function public.signup_account_check(text,text)to service_role;
notify pgrst,'reload schema';

-- Defence in depth: nothing in the private schema is executable by PUBLIC/anon, now or in future.
-- (Policy helpers keep their explicit grants to `authenticated`; service_role entry points live in public.)
revoke execute on all functions in schema private from public, anon;
alter default privileges in schema private revoke execute on functions from public, anon;

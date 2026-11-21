#!/usr/bin/env bash
# Race test: N parallel bookings for the same dates against a type with 3 units. Exactly 3 may succeed.
# Needs psql and a running local stack:  supabase start && supabase db reset && ./supabase/tests/concurrency.sh
set -euo pipefail
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
N="${N:-12}"
U=a1000000-0000-0000-0000-000000000001; T=a2000000-0000-0000-0000-000000000001
P=a3000000-0000-0000-0000-000000000001; TY=a4000000-0000-0000-0000-000000000001; G=a5000000-0000-0000-0000-000000000001

psql "$DB_URL" -q -v ON_ERROR_STOP=1 <<SQL
delete from public.tenants where id = '$T';
insert into auth.users (id, email) values ('$U', 'conc@test.local') on conflict do nothing;
insert into public.tenants (id, name, slug) values ('$T', 'Conc Test', 'conc-test');
insert into public.tenant_memberships (tenant_id, user_id, role) values ('$T', '$U', 'owner');
insert into public.properties (id, tenant_id, name, property_type) values ('$P', '$T', 'Conc Prop', 'hotel');
insert into public.accommodation_types (id, tenant_id, property_id, name, max_occupancy, base_rate) values ('$TY', '$T', '$P', 'Std', 2, 500);
insert into public.accommodation_units (tenant_id, property_id, type_id, name) values ('$T','$P','$TY','S1'),('$T','$P','$TY','S2'),('$T','$P','$TY','S3');
insert into public.guests (id, tenant_id, full_name) values ('$G', '$T', 'Race Guest');
SQL

seq "$N" | xargs -P "$N" -I{} psql "$DB_URL" -q -c "
  set local role authenticated;
  select set_config('request.jwt.claims', '{\"sub\":\"$U\",\"role\":\"authenticated\"}', true);
  select public.create_reservation('$P','$G','$TY','2027-09-01','2027-09-03',1,0,null,'direct','race-{}');" >/dev/null 2>&1 || true

HOLDS=$(psql "$DB_URL" -Atc "select count(*) from public.unit_holds where tenant_id='$T' and active")
DISTINCT=$(psql "$DB_URL" -Atc "select count(distinct unit_id) from public.unit_holds where tenant_id='$T' and active")
psql "$DB_URL" -q -c "delete from public.tenants where id = '$T'"
echo "active holds: $HOLDS (distinct units: $DISTINCT), expected 3"
[ "$HOLDS" = "3" ] && [ "$DISTINCT" = "3" ] && echo PASS || { echo FAIL; exit 1; }

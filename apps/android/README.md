# Staff app (Android, Kotlin + Jetpack Compose)

Milestone 6 slice: sign in, property switch, My tasks / Unassigned tasks (claim, start, done), room status.
Talks to Supabase only through PostgREST + the task RPCs (`claim_task`, `set_task_status`); RLS decides what each user sees.

## Run
1. `supabase start` in the repo root; note the API URL and anon key from `supabase status`.
2. `cp local.properties.example local.properties` and fill in the anon key (emulator reaches the host at `10.0.2.2`).
3. Open `apps/android` in Android Studio (it creates the Gradle wrapper), run on an emulator.
4. Sign in with a staff user that has a property membership and role (create one in Studio, then insert `tenant_memberships`, `property_memberships`, `user_roles`).

## Not yet
Guest requests, kitchen orders, push notifications (FCM + notification worker), profile screen, offline cache, instrumented tests.
Library versions are pinned at the time of writing; bump supabase-kt/Compose as needed.

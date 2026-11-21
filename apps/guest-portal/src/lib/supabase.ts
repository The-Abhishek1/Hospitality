import { createClient } from "@supabase/supabase-js";

// Anonymous, stateless client. Authority comes only from the link token passed to the portal_* functions.
export const anon = () =>
  createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });

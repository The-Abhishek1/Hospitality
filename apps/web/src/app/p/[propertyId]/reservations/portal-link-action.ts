"use server";
import { createClient } from "@/lib/supabase/server";

// Returns the link to the staff member once; only a hash of the token is stored in the database.
export async function createPortalLink(_prev: { link?: string; error?: string } | null, fd: FormData) {
  const supabase = await createClient();
  const { data: token, error } = await supabase.rpc("create_guest_portal_link", { p_reservation: String(fd.get("reservation")) });
  if (error) return { error: error.message };
  const base = (process.env.GUEST_PORTAL_URL ?? "http://localhost:3001").replace(/\/$/, "");
  return { link: `${base}/s/${token}` };
}

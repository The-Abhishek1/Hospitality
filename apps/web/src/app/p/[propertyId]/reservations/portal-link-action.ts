"use server";
import { isGuestTask,guestTaskPath } from "@/lib/guest-tasks";
import { createClient } from "@/lib/supabase/server";

// Returns the link to the staff member once; only a hash of the token is stored in the database.
export async function createPortalLink(_prev: { link?: string; error?: string } | null, fd: FormData) {
  const task=String(fd.get('task')??'documents');
  if(!isGuestTask(task))return{error:'Choose documents, food, bill or stay details.'};
  const supabase = await createClient();
  const { data: token, error } = await supabase.rpc("create_guest_portal_link", { p_reservation: String(fd.get("reservation")) });
  if (error) return { error: error.message };
  const base = (process.env.APP_URL ?? "http://localhost:3000").replace(/\/$/, "");
  return { link: `${base}${guestTaskPath(token,task)}` };
}

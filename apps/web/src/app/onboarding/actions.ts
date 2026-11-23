"use server";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

const PROPERTY_TYPES = ["hotel", "resort", "hostel", "homestay"];

export async function createWorkspace(formData: FormData) {
  const business = String(formData.get("business") ?? "").trim();
  const property = String(formData.get("property") ?? "").trim();
  const type = String(formData.get("type"));
  const timezone = String(formData.get("timezone") || "Asia/Kolkata");
  const currency = String(formData.get("currency") || "INR");
  const request = String(formData.get("request") || "");
  const fail = (m: string) => redirect(`/onboarding?error=${encodeURIComponent(m)}`);

  if (business.length < 2 || property.length < 2 || business.length > 120 || property.length > 120) fail("Names must be 2–120 characters.");
  if (!PROPERTY_TYPES.includes(type)) fail("Choose a property type.");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request)) fail("Refresh the setup form and try again.");
  try { new Intl.DateTimeFormat('en', {timeZone: timezone}).format(); } catch { fail("Choose a valid hotel timezone."); }
  if (!Intl.supportedValuesOf('currency').includes(currency)) fail("Choose a supported hotel currency.");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_hotel_workspace", {p_request:request,p_business:business,p_property:property,p_type:type,p_timezone:timezone,p_currency:currency});
  if (error || !data?.property_id) fail(error?.code==='22023' ? error.message : "Could not create your hotel. Refresh and try again.");
  redirect(`/p/${data.property_id}/settings?created=1`);
}

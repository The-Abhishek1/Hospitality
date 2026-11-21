"use server";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

const PROPERTY_TYPES = ["hotel", "resort", "hostel", "homestay"];

const slugify = (s: string) =>
  s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);

export async function createWorkspace(formData: FormData) {
  const business = String(formData.get("business") ?? "").trim();
  const property = String(formData.get("property") ?? "").trim();
  const type = String(formData.get("type"));
  const timezone = String(formData.get("timezone") || "Asia/Kolkata");
  const fail = (m: string) => redirect(`/onboarding?error=${encodeURIComponent(m)}`);

  if (business.length < 2 || property.length < 2) fail("Names must be at least 2 characters.");
  if (!PROPERTY_TYPES.includes(type)) fail("Choose a property type.");

  const supabase = await createClient();
  const slug = `${slugify(business) || "tenant"}-${Math.random().toString(36).slice(2, 6)}`;

  // Identity comes from the session inside the RPC; the client never supplies a user or role.
  const { data: tenantId, error } = await supabase.rpc("create_tenant", { p_name: business, p_slug: slug });
  if (error) fail(error.message);

  const { error: propError } = await supabase
    .from("properties")
    .insert({ tenant_id: tenantId, name: property, property_type: type, timezone });
  if (propError) fail(propError.message);

  redirect("/dashboard");
}

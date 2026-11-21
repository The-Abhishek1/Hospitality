// Seeds a demo tenant through the REAL API paths (auth admin API, RPCs, RLS-checked inserts), so it doubles as a smoke test.
// Usage: eval "$(supabase status -o env | sed 's/^/export /')"; SUPABASE_URL=$API_URL SUPABASE_ANON_KEY=$ANON_KEY SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY node scripts/seed-demo.mjs
import { createClient } from "@supabase/supabase-js";

const url = process.env.SUPABASE_URL ?? "http://127.0.0.1:54321";
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;   // used ONLY here, to create auth users; never ship it in an app
if (!anonKey || !serviceKey) { console.error("Set SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY (see `supabase status`)."); process.exit(1); }

const PASSWORD = process.env.DEMO_PASSWORD ?? "Demo-pass-123!";
const opts = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(url, serviceKey, opts);
const must = ({ data, error }, what) => { if (error) throw new Error(`${what}: ${error.message}`); return data; };
const login = async (email) => { const c = createClient(url, anonKey, opts); must(await c.auth.signInWithPassword({ email, password: PASSWORD }), `sign in ${email}`); return c; };

const USERS = [
  ["owner@demo.test", "Olivia Owner"], ["frontdesk@demo.test", "Farah Frontdesk"],
  ["housekeeping@demo.test", "Hari Housekeeping"], ["kitchen@demo.test", "Kiran Kitchen"],
];
for (const [email, name] of USERS) {
  const { error } = await admin.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true, user_metadata: { full_name: name } });
  if (error && !/already|registered|exists/i.test(error.message)) throw error;
}

const owner = await login("owner@demo.test");
const existing = must(await owner.from("tenants").select("id").eq("slug", "demo-hotel"), "check existing");
const tenantId = existing[0]?.id ?? must(await owner.rpc("create_tenant", { p_name: "Demo Hospitality", p_slug: "demo-hotel" }), "create tenant");
// A failed property insert leaves the tenant behind. Allow that run to resume.
const properties = must(await owner.from("properties").select("id").eq("tenant_id", tenantId), "check existing properties");
if (properties.length) { console.log("Demo tenant already has properties; skipping seed to avoid duplicate data."); process.exit(0); }
const prop = must(await owner.from("properties").insert({ tenant_id: tenantId, name: "Demo Beach Hotel", property_type: "hotel", timezone: "Asia/Kolkata" }).select("id").single(), "property");
const base = { tenant_id: tenantId, property_id: prop.id };

const types = {};
for (const [name, occ, rate] of [["Deluxe", 2, 3500], ["Suite", 4, 7500]]) {
  types[name] = must(await owner.from("accommodation_types").insert({ ...base, name, max_occupancy: occ, base_rate: rate }).select("id").single(), `type ${name}`).id;
}
const units = [["D101", "Deluxe"], ["D102", "Deluxe"], ["D103", "Deluxe"], ["D104", "Deluxe"], ["S201", "Suite"], ["S202", "Suite"]];
must(await owner.from("accommodation_units").insert(units.map(([name, t]) => ({ ...base, type_id: types[t], name }))), "units");

const cat = must(await owner.from("menu_categories").insert({ ...base, name: "Room service" }).select("id").single(), "menu category");
must(await owner.from("menu_items").insert([
  { ...base, category_id: cat.id, name: "Masala tea", price: 80, tax_rate_percent: 5 },
  { ...base, category_id: cat.id, name: "Club sandwich", price: 350, tax_rate_percent: 5 },
  { ...base, category_id: cat.id, name: "Fresh lime soda", price: 120, tax_rate_percent: 5 },
]), "menu items");

const sc = must(await owner.from("service_categories").insert({ ...base, name: "Amenities" }).select("id").single(), "service category");
const svc = must(await owner.from("service_catalog").insert([
  { ...base, category_id: sc.id, name: "Extra towels" }, { ...base, category_id: sc.id, name: "Late checkout" },
]).select("id, name"), "services");
must(await owner.from("service_routing_rules").insert({ ...base, catalog_id: svc.find((s) => s.name === "Extra towels").id, task_kind: "housekeeping", sla_minutes: 30 }), "routing rule");

const grants = { "frontdesk@demo.test": "front_desk", "housekeeping@demo.test": "housekeeping", "kitchen@demo.test": "kitchen" };
for (const [email, role] of Object.entries(grants)) {
  must(await owner.rpc("invite_staff", { p_tenant: tenantId, p_email: email, p_tenant_role: "member", p_grants: [{ property_id: prop.id, role_key: role }] }), `invite ${email}`);
  const c = await login(email);
  must(await c.rpc("accept_staff_invitations"), `accept ${email}`);
}

const iso = (n) => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);
const guests = must(await owner.from("guests").insert([
  { tenant_id: tenantId, full_name: "Asha Rao", phone: "+919800000001" }, { tenant_id: tenantId, full_name: "Ben Carter", phone: "+919800000002" },
]).select("id"), "guests");
const r1 = must(await owner.rpc("create_reservation", { p_property: prop.id, p_guest: guests[0].id, p_type: types.Deluxe, p_check_in: iso(0), p_check_out: iso(2), p_adults: 2, p_children: 0 }), "reservation 1");
must(await owner.rpc("check_in_reservation", { p_id: r1 }), "check in");
must(await owner.rpc("create_reservation", { p_property: prop.id, p_guest: guests[1].id, p_type: types.Suite, p_check_in: iso(5), p_check_out: iso(8), p_adults: 2, p_children: 1 }), "reservation 2");

console.log(`\nDemo data ready. Password for every user: ${PASSWORD}`);
console.log(USERS.map(([e]) => `  ${e}`).join("\n"));
console.log(`\nWeb app: http://localhost:3000  (property ${prop.id})\n`);

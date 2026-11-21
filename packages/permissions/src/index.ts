// Keep in sync with public.permissions seeded in supabase/migrations.
export const PERMISSIONS = [
  "reservations.read", "reservations.write", "frontdesk.manage",
  "tasks.read", "tasks.write", "tasks.assign",
  "guest_requests.read", "guest_requests.manage", "housekeeping.manage",
  "orders.read", "orders.write", "finance.read", "finance.write", "staff.manage", "inventory.manage", "billing.manage", "orders.place", "whatsapp.use",
] as const;

export type Permission = (typeof PERMISSIONS)[number];
export type TenantRole = "owner" | "admin" | "member";

// UI hint only. The database (RLS + has_permission) is the enforcement point.
export const can = (granted: ReadonlySet<Permission>, role: TenantRole, p: Permission) =>
  role !== "member" || granted.has(p);

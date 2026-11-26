import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { publicGuestPath } from "@/lib/guest-tasks";
import { safeNext } from "@/lib/auth";

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });
  // Guest tasks authenticate with a stay token, independently of staff sessions.
  if (["/privacy", "/data-deletion"].includes(request.nextUrl.pathname) || publicGuestPath(request.nextUrl.pathname) || /^\/api\/payments\/razorpay\/webhook\/[a-f0-9-]{36}$/.test(request.nextUrl.pathname)) return response;
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll(list: { name: string; value: string; options: CookieOptions }[]) {
          list.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        },
      },
    },
  );

  // getUser() verifies the token with Supabase Auth; never trust getSession() on the server.
  const { data: { user } } = await supabase.auth.getUser();
  const path = request.nextUrl.pathname;
  const publicPage = ["/login", "/signup", "/forgot-password"].includes(path);
  const callback = path === "/auth/confirm";
  const go = (destination: string) => {
    const target = NextResponse.redirect(new URL(destination, request.url));
    response.cookies.getAll().forEach((cookie) => target.cookies.set(cookie));
    return target;
  };
  if (!user && !publicPage && !callback) return go(`/login?next=${encodeURIComponent(safeNext(path + request.nextUrl.search))}`);
  if (user && (path === "/login" || path === "/signup")) return go(safeNext(request.nextUrl.searchParams.get("next")));
  return response;
}

export const config = { matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"] };

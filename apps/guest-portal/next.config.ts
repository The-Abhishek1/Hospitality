import { PHASE_DEVELOPMENT_SERVER } from "next/constants";
// The secret link token lives in the URL path, so: never leak it via Referer, never cache pages, no framing.
const config = {
  async headers() {
    return [{
      source: "/(.*)",
      headers: [
        { key: "Referrer-Policy", value: "no-referrer" },
        { key: "Cache-Control", value: "no-store" },
        { key: "X-Frame-Options", value: "DENY" },
        { key: "X-Content-Type-Options", value: "nosniff" },
        { key: "X-Robots-Tag", value: "noindex, nofollow" },
      ],
    }];
  },
};
export default (phase: string) => ({
  ...config,
  distDir: phase === PHASE_DEVELOPMENT_SERVER ? ".next-dev" : ".next-production",
  typescript: { tsconfigPath: phase === PHASE_DEVELOPMENT_SERVER ? "tsconfig.json" : "tsconfig.build.json" },
});

import { PHASE_DEVELOPMENT_SERVER } from "next/constants";
import path from "node:path";

// Keep `next build` from replacing assets used by an active `next dev` server.
export default (phase: string) => ({
  async headers(){return [{source:'/s/:path*',headers:[{key:'Referrer-Policy',value:'no-referrer'},{key:'Cache-Control',value:'no-store'},{key:'X-Frame-Options',value:'DENY'},{key:'X-Content-Type-Options',value:'nosniff'},{key:'X-Robots-Tag',value:'noindex, nofollow'}]}];},
  outputFileTracingRoot: path.resolve(__dirname, "../.."),
  distDir: phase === PHASE_DEVELOPMENT_SERVER ? ".next-dev" : ".next",
  typescript: {
    tsconfigPath: phase === PHASE_DEVELOPMENT_SERVER ? "tsconfig.json" : "tsconfig.build.json",
  },
});

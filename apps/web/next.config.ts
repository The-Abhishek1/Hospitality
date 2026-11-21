import { PHASE_DEVELOPMENT_SERVER } from "next/constants";
import path from "node:path";

// Keep `next build` from replacing assets used by an active `next dev` server.
export default (phase: string) => ({
  outputFileTracingRoot: path.resolve(__dirname, "../.."),
  distDir: phase === PHASE_DEVELOPMENT_SERVER ? ".next-dev" : ".next",
  typescript: {
    tsconfigPath: phase === PHASE_DEVELOPMENT_SERVER ? "tsconfig.json" : "tsconfig.build.json",
  },
});

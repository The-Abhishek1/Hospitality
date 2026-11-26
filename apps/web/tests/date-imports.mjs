// The lightweight VM/data-URL test harnesses do not have Next's @/ alias resolver.
// Inline the real pure date module before transpilation so tests exercise the same code.
import {readFileSync} from 'node:fs';
const helpers=readFileSync(new URL('../src/lib/date-format.ts',import.meta.url),'utf8').replace(/export /g,'');
export function withDateHelpers(source){return source.replace(/import\s*\{[^}]*\}\s*from\s*['"](?:@\/lib|\.)\/date-format['"];?/g,helpers);}

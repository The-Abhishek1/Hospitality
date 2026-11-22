// Supabase's API deployer uploads dependencies from the functions tree.
// Keep deployable copies byte-identical to the unit-tested canonical implementations.
import{readFileSync,writeFileSync}from'node:fs';import{fileURLToPath}from'node:url';import path from'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),check=process.argv.includes('--check');
const files=[['packages/whatsapp-security/index.mjs','supabase/functions/_shared/whatsapp-crypto.js'],['packages/whatsapp-security/templates.mjs','supabase/functions/_shared/whatsapp-templates.js'],['services/notification-worker/src/transport.ts','supabase/functions/_shared/whatsapp-transport.ts']];
for(const[from,to]of files){const source=readFileSync(path.join(root,from),'utf8');if(check){let target;try{target=readFileSync(path.join(root,to),'utf8');}catch{}if(source!==target)throw Error(`Run node scripts/sync-whatsapp-edge.mjs: ${to} is stale`);}else writeFileSync(path.join(root,to),source);}
console.log(check?'Edge helpers match canonical implementations.':'Edge helpers synchronized.');

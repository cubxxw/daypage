import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(packageDir, "../..");
const outfile = resolve(packageDir, "dist/edge.js");

await build({
  entryPoints: [resolve(repositoryRoot, "supabase/functions/daypage-mcp/index.ts")],
  outfile,
  bundle: true,
  platform: "neutral",
  format: "esm",
  packages: "external",
  target: "es2022",
  sourcemap: false,
});

let source = await readFile(outfile, "utf8");
source = source
  .replaceAll('"@modelcontextprotocol/sdk/', '"npm:@modelcontextprotocol/sdk@1.30.0/')
  .replaceAll('"@supabase/supabase-js"', '"npm:@supabase/supabase-js@2.108.2"')
  .replaceAll('"zod/v4"', '"npm:zod@4.4.3/v4"');

const unsupportedImports = [...source.matchAll(/from\s+"(?!npm:|node:)([^".][^"]*)"/g)]
  .map((match) => match[1]);
if (unsupportedImports.length > 0) {
  throw new Error(`Edge bundle contains unsupported bare imports: ${unsupportedImports.join(", ")}`);
}

await writeFile(outfile, source);
console.info(`Built ${outfile}`);

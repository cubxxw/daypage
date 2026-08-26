import { copyFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const examplePath = resolve(repositoryRoot, "supabase/functions/.env.example");
const localPath = resolve(repositoryRoot, "supabase/functions/.env");

try {
  await stat(localPath);
  const [example, local] = await Promise.all([
    readFile(examplePath, "utf8"),
    readFile(localPath, "utf8"),
  ]);
  const existingKeys = new Set(
    local.split(/\r?\n/)
      .map((line) => /^\s*([A-Z_][A-Z0-9_]*)\s*=/.exec(line)?.[1])
      .filter(Boolean),
  );
  const missing = example.split(/\r?\n/).filter((line) => {
    const key = /^\s*([A-Z_][A-Z0-9_]*)\s*=/.exec(line)?.[1];
    return key && !existingKeys.has(key);
  });
  if (missing.length > 0) {
    const separator = local.endsWith("\n") ? "" : "\n";
    await writeFile(localPath, `${local}${separator}${missing.join("\n")}\n`);
    console.info(`Added ${missing.length} missing local backend setting(s)`);
  } else {
    console.info("Using existing supabase/functions/.env");
  }
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
  await mkdir(dirname(localPath), { recursive: true });
  await copyFile(examplePath, localPath);
  console.info("Created supabase/functions/.env from the local-only example");
}

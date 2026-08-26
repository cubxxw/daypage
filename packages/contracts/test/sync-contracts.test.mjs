import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";
import { attachmentManifestHash } from "../manifest-hash.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const load = async (relativePath) =>
  JSON.parse(await readFile(resolve(root, relativePath), "utf8"));

const cases = [
  ["sync push", "schemas/sync-push-v1.schema.json", "fixtures/sync-push-v1.json"],
  ["sync push result", "schemas/sync-push-result-v1.schema.json", "fixtures/sync-push-result-v1.json"],
  ["sync pull request", "schemas/sync-pull-request-v1.schema.json", "fixtures/sync-pull-request-v1.json"],
  ["sync pull page", "schemas/sync-pull-page-v1.schema.json", "fixtures/sync-pull-page-v1.json"],
  ["sync push v2", "schemas/sync-push-v2.schema.json", "fixtures/sync-push-v2.json"],
  ["sync push result v2", "schemas/sync-push-result-v2.schema.json", "fixtures/sync-push-result-v2.json"],
  ["sync pull page v2", "schemas/sync-pull-page-v2.schema.json", "fixtures/sync-pull-page-v2.json"],
  ["attachment upload prepare v2", "schemas/attachment-upload-prepare-v2.schema.json", "fixtures/attachment-upload-prepare-v2.json"],
  ["attachment upload prepared v2", "schemas/attachment-upload-prepared-v2.schema.json", "fixtures/attachment-upload-prepared-v2.json"],
];

for (const [name, schemaPath, fixturePath] of cases) {
  test(`${name} fixture conforms to its canonical schema`, async () => {
    const ajv = new Ajv2020({ allErrors: true, strict: true });
    const validate = ajv.compile(await load(schemaPath));
    const valid = validate(await load(fixturePath));
    assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  });
}

test("delete operations cannot smuggle an upsert payload", async () => {
  const fixture = await load("fixtures/sync-push-v1.json");
  fixture.p_operations[1].payload = fixture.p_operations[0].payload;
  const validate = new Ajv2020({ allErrors: true }).compile(
    await load("schemas/sync-push-v1.schema.json")
  );
  assert.equal(validate(fixture), false);
});

test("upserts require a non-empty body and a content hash", async () => {
  const fixture = await load("fixtures/sync-push-v1.json");
  fixture.p_operations[0].payload.body = "";
  delete fixture.p_operations[0].content_hash;
  const validate = new Ajv2020({ allErrors: true }).compile(
    await load("schemas/sync-push-v1.schema.json")
  );
  assert.equal(validate(fixture), false);
});

test("pull fixture preserves a strict monotonic cursor", async () => {
  const page = await load("fixtures/sync-pull-page-v1.json");
  const after = 40;
  const sequences = page.changes.map((change) => change.change_sequence);
  assert.deepEqual(sequences, [...sequences].sort((a, b) => a - b));
  assert.equal(new Set(sequences).size, sequences.length);
  assert.ok(sequences.every((sequence) => sequence > after));
  assert.equal(page.next_cursor, sequences.at(-1));
});

test("v2 fixture carries its canonical attachment manifest hash", async () => {
  const fixture = await load("fixtures/sync-push-v2.json");
  const operation = fixture.p_operations[0];
  assert.equal(
    attachmentManifestHash(operation.payload.attachments),
    operation.attachment_manifest_hash
  );
});

test("v2 delete cannot smuggle attachment durability", async () => {
  const fixture = await load("fixtures/sync-push-v2.json");
  fixture.p_operations[1].attachment_manifest_hash = fixture.p_operations[0].attachment_manifest_hash;
  const validate = new Ajv2020({ allErrors: true }).compile(
    await load("schemas/sync-push-v2.schema.json")
  );
  assert.equal(validate(fixture), false);
});

test("v2 attachment path and MIME restrictions fail closed", async () => {
  const fixture = await load("fixtures/sync-push-v2.json");
  const attachment = fixture.p_operations[0].payload.attachments[0];
  attachment.object_key = "../other-user/photo.jpg";
  attachment.mime_type = "application/x-executable";
  const validate = new Ajv2020({ allErrors: true }).compile(
    await load("schemas/sync-push-v2.schema.json")
  );
  assert.equal(validate(fixture), false);
});

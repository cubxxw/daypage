import { createHash } from "node:crypto";

const utf8LengthPrefix = (value) => {
  const text = String(value);
  return `${Buffer.byteLength(text, "utf8")}:${text}`;
};

export function canonicalAttachmentManifest(attachments) {
  const ordered = [...attachments].sort((left, right) => left.position - right.position);
  const records = ordered.map((attachment) => {
    const fields = [
      attachment.position,
      attachment.kind,
      attachment.content_sha256,
      attachment.size_bytes,
      attachment.mime_type,
      attachment.object_key,
      attachment.original_filename,
      attachment.duration_ms ?? "",
      attachment.transcript ?? "",
      attachment.transcription_status ?? "",
    ];
    return fields.map(utf8LengthPrefix).join("");
  });
  return utf8LengthPrefix("2") + records.map(utf8LengthPrefix).join("");
}

export function attachmentManifestHash(attachments) {
  return createHash("sha256")
    .update(canonicalAttachmentManifest(attachments), "utf8")
    .digest("hex");
}

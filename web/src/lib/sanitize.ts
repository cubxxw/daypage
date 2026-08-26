// Memo bodies are Markdown/plain text, not HTML. Remove the two characters
// that can delimit an HTML tag instead of trying to deny-list particular tags,
// attributes, or URL schemes. Single-character replacement cannot recreate a
// dangerous sequence and leaves Markdown syntax and ordinary entities intact.
export function sanitizeMemoBody(text: string): string {
  return text.replaceAll("<", "").replaceAll(">", "");
}

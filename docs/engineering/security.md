# Security and privacy

- Never commit API keys, generated secret values, auth/session state, cookies, private
  vault data, transcripts, or user-identifying screenshots.
- Treat vault paths and content as private. Tests use isolated fixtures and prove cleanup.
- Do not auto-start repository MCP servers that request ambient credentials or broad memory.
- Pin executable package/tool versions in automation; avoid `@latest`.
- External writes and production changes require explicit authorization and scoped credentials.
- Redact commands and artifacts before issues, PRs, logs, or handoffs.
- Persistence, auth, sync, and remote-schema changes require threat, migration, and rollback review.

Report suspected credential exposure or user-data loss to the lead immediately and stop
publishing further artifacts.

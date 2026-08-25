# Security and privacy

- Never commit API keys, generated secret values, auth/session state, cookies, private
  vault data, transcripts, or user-identifying screenshots.
- Supabase `sb_publishable_...` and legacy `anon` keys are public mobile-client
  configuration, not privileged secrets. They may be generated into the IPA and must be
  constrained by RLS plus the user's JWT. Never ship `sb_secret_...`, `service_role`, or
  database credentials in any client target.
- Treat vault paths and content as private. Tests use isolated fixtures and prove cleanup.
- Do not auto-start repository MCP servers that request ambient credentials or broad memory.
- Pin executable package/tool versions in automation; avoid `@latest`.
- External writes and production changes require explicit authorization and scoped credentials.
- Redact commands and artifacts before issues, PRs, logs, or handoffs.
- Persistence, auth, sync, and remote-schema changes require threat, migration, and rollback review.

Report suspected credential exposure or user-data loss to the lead immediately and stop
publishing further artifacts.

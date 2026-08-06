# Codex host adapter

Follow the repository constitution in `../AGENTS.md` and discover project roles
through `../.agents/manifest.yaml`.

- `.codex/config.toml` contains only trusted repository defaults.
- `.codex/agents/*.toml` are thin host adapters for canonical roles under
  `../.agents/roles/`.
- Repository configuration does not auto-start external MCP servers. Keep
  credentials and private MCP configuration in the user's Codex configuration.
- Do not duplicate product architecture or workflow policy here.

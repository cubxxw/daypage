# Claude Code adapter

Follow [AGENTS.md](AGENTS.md) as the repository constitution and
[.agents/manifest.yaml](.agents/manifest.yaml) as the Agent Team registry.

Claude-specific rules:

- Load the closest applicable `AGENTS.md`; never replace or contradict the root contract.
- Treat `.agents/` as canonical. Files under `.claude/` are host adapters, not a second
  source of architecture or workflow truth.
- Use `.agents/skills/daypage/SKILL.md` for repository context.
- Preserve explicit ownership in parallel work and return the canonical handoff fields.
- Do not infer permission to commit, push, create/merge a PR, deploy, release, or write to
  an external service.

Current architecture, setup, testing, and Agent Team documentation is indexed from
[docs/README.md](docs/README.md).

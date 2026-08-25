# DeepSeek Harness host adapter

This directory is the repository-owned adapter for running DayPage's canonical
development Agent Team through DeepSeek Harness (`dsh`). It does not replace the
product-facing Go runtime under `agentry/`.

## Contract

- `.dsh/version` pins the exact developer-preview release.
- `.dsh/daypage.patch.yml` selects the DeepSeek model from `DEEPSEEK_MODEL` while
  leaving the shipped `standard` preset responsible for tools, instructions, skills,
  compaction, goals, plans, and subagents.
- `scripts/agent/dsh.py` is the only supported launcher. It passes only
  `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, and `DEEPSEEK_MODEL` from the selected
  dotenv file and does not source it as shell code.
- The launcher disables both Harness bootstrap and session-plugin telemetry,
  defaults to `workspace-write` with interactive approval, and keeps DSH state
  outside the repository.
- The repository patch replaces the host-native picker with DSH's in-app directory
  browser while the server remains bound to `127.0.0.1`, keeping human and automated
  Web UI sessions on one observable path.
- Root `AGENTS.md` and `.agents/skills` remain the sources of project policy and
  repository skills. Do not copy their content into this adapter.

## Commands

```sh
make dsh-doctor
make dsh-config
make dsh-web
```

Use `DAYPAGE_DSH_ENV_FILE` to name a dotenv file explicitly and
`DAYPAGE_DSH_HOME` to override the default `~/.dsh-daypage` state directory. Both
are operator configuration; neither belongs in repository files.

Runtime profiles, credentials, settings, sessions, storage, logs, and UI evidence
must remain ignored. The versioned Agentic test cases and scoring rubric live in
`docs/engineering/dsh-agentic-testing.md`.

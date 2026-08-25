# ADR-0014: DeepSeek Harness as a development Agent Team host

- **Status:** Accepted
- **Date:** 2026-08-26
- **Issue:** [#880](https://github.com/getyak/daypage/issues/880)

## Context

DayPage's development control plane is host-neutral under `.agents`, with Codex and
Claude adapters. The repository also contains `agentry/`, a product-facing Go agent
runtime with a separate security and lifecycle boundary. DeepSeek Harness (`dsh`)
provides a plugin-composed coding-agent host with durable sessions, plans, goals,
skills, subagents, filesystem and shell tools, sandboxing, approvals, and a Web UI.

The local operator environment already carries DeepSeek provider configuration, but
the dotenv file also contains unrelated product and service credentials. Sourcing or
copying that whole file into a coding-agent process would unnecessarily expand its
credential boundary. DSH is a developer preview, so an unpinned executable command
would also make repository behavior drift without review.

## Decision

1. Add DSH as an optional third host adapter for the canonical development Agent Team.
   It does not replace or become `agentry/`.
2. Pin one exact DSH version in `.dsh/version`; the repository launcher invokes only
   that version through the existing pnpm toolchain.
3. Keep profiles, credentials, settings, sessions, storage, logs, and runtime evidence
   outside version control and outside the repository by default.
4. Parse, but never shell-source, the selected dotenv file. Pass only
   `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, and `DEEPSEEK_MODEL` to a scrubbed child
   environment. Accept only the official HTTPS DeepSeek endpoint by default.
5. Use DSH's shipped `standard` and `code` presets. Root `AGENTS.md`,
   `.agents/manifest.yaml`, canonical role/workflow files, and `.agents/skills` remain
   the sources of repository behavior.
6. Default to `workspace-write` with interactive approval and disable both bootstrap
   and session-plugin telemetry. A wider permission preset is an explicit operator
   choice, not repository policy.
7. Keep versioned, secret-free Agentic test definitions and scoring in current
   engineering documentation. Keep raw sessions and screenshots local.
8. Replace the host-native picker with DSH's in-app directory browser so human and
   automated sessions share one testable workspace-selection flow while the server
   remains bound to `127.0.0.1`.

## Consequences

- A clean checkout gains a reproducible DSH Web UI without adding hundreds of Harness
  packages to DayPage's dependency graph.
- Existing Agent Team policy and skills work across Codex, Claude, and DSH without
  copied architecture facts.
- The DSH process does not inherit unrelated API keys, GitHub tokens, or application
  service credentials from the selected dotenv file or launching process.
- First launch downloads the pinned DSH package. A version upgrade is a reviewed
  repository change with contract and UI verification.
- DSH's file sandbox governs writes, not all reads or network destinations. The
  dedicated, scoped provider key and scrubbed environment remain required defenses.

## Alternatives considered

- **Replace `agentry/` with DSH:** rejected because it violates the accepted product
  runtime boundary and turns a host integration into a product rewrite.
- **Commit or copy the complete dotenv file:** rejected because it exposes unrelated
  credentials and permits bootstrap variables to affect the Harness process.
- **Install an unpinned global `dsh`:** rejected because developer-preview releases may
  break profiles and configuration without a repository diff.
- **Copy the shipped standard preset:** rejected because it forks a large volatile
  composition. DayPage layers policy through instructions, skills, and a small host
  patch instead.

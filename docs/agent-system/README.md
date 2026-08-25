# DayPage Agent Team

The development Agent Team combines a small canonical control plane with host-native
adapters:

```text
AGENTS.md
    |
.agents/manifest.yaml
    +-- roles / workflows
    +-- task / handoff / evidence schemas
    +-- context router / repository skill
    |
    +-- .codex adapters
    +-- .claude adapters
    +-- .dsh adapter + safe launcher
```

The lead owns task decomposition and integration. Product architect, iOS, web, agent
platform, QA, reviewer, and docs roles own bounded responsibilities. See
[team protocol](team-protocol.md) and [context layers](context-layers.md).

This system coordinates development. `agentry/` is a separate product runtime.

DeepSeek Harness is an optional host for the same control plane. Its repository adapter
pins the runtime and launch policy but does not duplicate roles, workflows, skills, or
product architecture. See [the DSH testing contract](../engineering/dsh-agentic-testing.md).

## Design principles

- One canonical constitution and manifest.
- Explicit, non-overlapping path ownership.
- Parallelize read-heavy or independent work; serialize shared-file integration.
- Machine-readable handoffs and evidence.
- Independent QA and review for material changes.
- No default remote writes, release, or destructive cleanup.

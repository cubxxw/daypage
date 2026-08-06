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
```

The lead owns task decomposition and integration. Product architect, iOS, web, agent
platform, QA, reviewer, and docs roles own bounded responsibilities. See
[team protocol](team-protocol.md) and [context layers](context-layers.md).

This system coordinates development. `agentry/` is a separate product runtime.

## Design principles

- One canonical constitution and manifest.
- Explicit, non-overlapping path ownership.
- Parallelize read-heavy or independent work; serialize shared-file integration.
- Machine-readable handoffs and evidence.
- Independent QA and review for material changes.
- No default remote writes, release, or destructive cleanup.

# ADR-0009: Native platform surfaces with shared product contracts

- **Status:** Accepted
- **Date:** 2026-08-25
- **Issues:** [#332](https://github.com/getyak/daypage/issues/332),
  [#789](https://github.com/getyak/daypage/issues/789),
  [#873](https://github.com/getyak/daypage/issues/873)

## Context

DayPage has a mature SwiftUI iOS client, a smaller native macOS client, a native Compose
Android client, a Next.js web product, Supabase-backed local-first sync, and a
user-scoped Cloud MCP service. The existing surfaces evolved independently: account
entry points, navigation, sync state, typography, and component geometry do not yet feel
like one product.

The product needs to reach Android, iOS, macOS, and web while preserving three qualities:

1. capture must remain instant and safe when offline;
2. Apple surfaces must be able to adopt system Liquid Glass and platform interaction
   conventions instead of approximating them in a lowest-common-denominator toolkit;
3. one account must expose one user-scoped data set and the same MCP authorization
   boundary on every device.

UI source sharing alone does not create those qualities. It can reduce initial screen
work, but it also makes native navigation, accessibility, text input, background work,
and new OS materials harder to adopt. Conversely, duplicating identity, sync, and data
semantics per platform creates correctness and security drift.

## Decision

### 1. Share contracts and behavior; keep shipping UI native to each surface

DayPage will use a **native-surfaces / shared-contracts** architecture:

| Surface | UI and app shell | Local runtime |
| --- | --- | --- |
| iOS / iPadOS | SwiftUI, native Liquid Glass when available | `DayPageKit`, Vault, revisioned outbox |
| macOS | SwiftUI with macOS navigation, commands, windows, and inspectors | `DayPageKit`, Vault, revisioned outbox |
| Android | Jetpack Compose with Material 3 adaptive primitives and DayPage tokens | Kotlin repositories, Room, WorkManager outbox |
| Web / PWA | Next.js + React, semantic HTML/CSS, server components where appropriate | IndexedDB draft/outbox where offline capture is enabled |

The iOS application will not be rewritten in Flutter, React Native, or shared Compose UI.
Compose Multiplatform remains an allowed prototyping tool and a possible shared Kotlin
domain implementation, but it is not the default Apple presentation layer. The expected
return from replacing the mature SwiftUI surface is smaller than the migration cost and
loss of immediate access to Apple platform APIs.

### 2. The cross-platform product kernel is a set of versioned contracts

The reusable kernel is platform-neutral and has five parts:

- **Identity contract:** one Supabase `auth.users.id` is the canonical account ID.
  Apple and email are identities attached to that user, not parallel DayPage accounts.
- **Memo contract:** stable UUIDs, UTC timestamps, explicit source/device metadata,
  tombstones, and versioned JSON schemas map to the existing Markdown/YAML Vault format.
- **Sync contract:** local commit first; durable idempotent operation outbox; per-device
  revision; server change sequence; exact acknowledgement receipts; deterministic
  conflict preservation. ADR-0008 remains authoritative.
- **Capability contract:** the Cloud MCP exposes bounded tools over OAuth/PAT and RLS.
  Clients do not embed service-role credentials or create a second agent-only database.
- **Experience contract:** semantic design tokens, account/sync state vocabulary,
  navigation information architecture, accessibility requirements, and motion intent.
  Each renderer maps those semantics to native components.

Contracts are generated or verified in CI from canonical schema/token sources. Shared
code is optional; shared semantics and conformance tests are mandatory.

### 3. Account and sync use one explicit state model everywhere

Every surface presents the same user-visible states:

```text
local_only
  -> authenticating
  -> bound_and_syncing
  -> synced
  -> offline_queued
  -> action_required
```

Authentication is optional for local capture. Signing in binds a local Vault/store to
the first account before any upload. A different account fails closed and requires an
explicit export/new-store decision; data is never silently uploaded under the new user.

"Sign out" means **sign out this device**. It removes the local session and stops network
sync without deleting local Vault content or signing out other devices. Global session
revocation and account deletion are separate, explicitly named actions.

Apple sign-in uses the system authorization surface on iOS/macOS and Supabase PKCE OAuth
on the web. Android may offer Apple web OAuth alongside email OTP, but it must resolve to
the same Supabase user ID. Provider email is profile metadata, not the tenant key.

### 4. Visual identity is editorial content plus platform-native chrome

The DayPage visual system has two layers:

- **Content layer:** warm paper/ink palette, editorial serif for reflective content,
  restrained amber accent, solid cards, generous whitespace, and low visual noise.
- **Chrome layer:** platform-native navigation, sheets, sidebars, toolbars, focus,
  keyboard, pointer, haptics, and accessibility behavior.

On iOS 27+ Liquid Glass is limited to the chrome layer. It is not nested and is not used
as the default content-card background. System materials are gated by availability;
iOS 16-26 keep an opaque/readable fallback. Reduce Transparency produces an opaque
surface and Reduce Motion replaces spatial transforms with a cross-fade.

Tokens use semantic names rather than platform color names and are generated to Swift,
Kotlin/Compose, and CSS. Geometry may map differently by platform: a semantic
`navigation.row` is not required to have the same pixel height on macOS and Android.

### 5. Navigation adapts instead of merely resizing

The shared information architecture is Capture/Today, Archive, Graph, Search/Ask, and
Settings/Account. Presentation varies by available width:

- compact phones: top chrome plus a modal navigation drawer or platform tab pattern;
- iPad and Android expanded widths: persistent navigation rail/sidebar + detail;
- macOS and desktop web: collapsible persistent sidebar, keyboard shortcuts, multi-window
  or inspector patterns where valuable.

Account identity and sync health are always reachable from the primary navigation and
Settings. Destructive account actions live in Account Center, not in the first-level
navigation list.

### 6. Android is added as a conforming client, not a backend fork

The Android implementation starts with a thin vertical slice:

1. Supabase Apple/email authentication and secure session storage;
2. local Room memo model and immediate local capture;
3. WorkManager-backed implementation of the ADR-0008 outbox/pull protocol;
4. Account Center and adaptive navigation shell;
5. conformance fixtures proving create/edit/delete/conflict behavior against iOS/macOS.

Android must not call a legacy API-key bridge or invent a second memo schema. The schema
and sync conformance gates below are prerequisites for each broader Android feature.

Implementation note (2026-08-25): `packages/contracts` now owns JSON Schema 2020-12
definitions and normative fixtures for push operations, exact receipts, pull requests,
and monotonic pull pages. AJV validates the wire fixtures, while
`SyncContractFixtureTests` decodes those same files into the shipping Swift outbox and
pull types. This completes the protocol-conformance prerequisite for the first Android
vertical slice; Kotlin must consume and pass the same fixtures rather than copying their
shape into an undocumented DTO.

Android implementation note (2026-08-25): `android/` now contains the first native
vertical slice. A Noter is atomically committed to the canonical raw Markdown Vault
before a Room transaction indexes it and records its replacement outbox intent.
WorkManager pushes exact receipts and pulls monotonic pages. Pulled changes and conflict
copies are mirrored to the Vault before their server cursor advances, so a failed disk
write remains replayable. Concurrent remote edits preserve the local value as a new
conflict memo, and the Compose shell adapts from a modal drawer to a persistent
navigation rail. Apple OAuth and email magic links use a Keystore-protected PKCE attempt
and resolve to the same Supabase session used by the RPC client. The Android JVM suite
reads canonical contract fixtures directly and covers storage recovery plus compact and
expanded Compose semantics without copying protocol examples.

## Consequences

### Positive

- Apple platforms can adopt OS 27+ materials, accessibility, commands, widgets, and
  background behavior immediately.
- Android receives first-class Compose and adaptive-layout behavior rather than an iOS
  skin.
- Identity, sync, MCP security, and conflict behavior have one testable definition.
- Existing SwiftUI, Next.js, DayPageKit, Supabase, and MCP investments remain useful.

### Costs

- Screens are implemented more than once and require cross-platform visual review.
- Token/schema generators and conformance fixtures become release-critical tooling.
- Product behavior must be specified semantically; screenshots alone are insufficient.
- Android adds a first-class Gradle/SDK build to CI and maintains native UI separately.

## Alternatives considered

### Flutter for all clients

Rejected for the current product. It offers broad target coverage and consistent custom
rendering, but requires replacing mature SwiftUI and web surfaces, adds a non-native
rendering layer around the most OS-sensitive parts of the experience, and does not remove
the need for platform-specific auth, storage, background execution, and accessibility.

### React Native / Expo plus a macOS fork

Rejected as the primary architecture. It would share React knowledge with web but not the
actual Next.js rendering model, while macOS and the newest Apple UI APIs still require
substantial native bridging.

### Compose Multiplatform UI on every native client

Not selected as the default, despite stable mobile/desktop support. It is suitable for a
new Kotlin-first product, but replacing DayPage's Apple UI would create a large migration
before delivering Android value. Kotlin Multiplatform may still share future contract or
sync code if that boundary proves smaller and safer than protocol-level sharing.

### Web/PWA wrapper on all platforms

Rejected for primary capture. It cannot match the reliability and integration expected
for background sync, widgets, shortcuts, system authentication, files, haptics, and
platform-native navigation.

## Verification and rollout

- Keep ADR-0008 multi-device and cross-user isolation tests as release blockers.
- Add shared JSON fixtures for memo operations and conflict outcomes before Android work.
- Add token drift checks for Swift, Kotlin, and CSS outputs.
- Verify account state, sign-in, sign-out-this-device, offline queue, and recovery on
  each platform.
- Visual QA covers compact/expanded widths, light/dark, AX5 or largest font scale,
  Increase Contrast, Reduce Transparency, Reduce Motion, keyboard, and pointer/focus.
- Roll out by vertical slice: Account Center -> navigation shell -> Android capture/sync
  slice -> remaining feature parity. Do not wait for pixel parity before testing the data
  contract.

# PRD: Authentication — Login & Registration

## Introduction

Add a full authentication system to DayPage iOS app using Supabase Auth. Users can sign in via Apple Sign-In or Email Magic Link. Email serves as the single canonical identity for cross-device sync. The UI follows a dark, textured, high-quality aesthetic — think Notion's clean typography principles applied to a deep dark surface, with subtle grain, generous whitespace, and editorial-grade type hierarchy.

Anonymous local usage remains fully supported; auth is the gateway to sync, not a hard paywall.

---

## Goals

- Let users create an account and sign in with Apple ID or Email Magic Link
- Make `email` the single unique identifier across all future platforms (iOS, Web)
- Keep local-first usage intact — login is optional, prompts appear contextually
- Ship a visually distinctive auth UI that feels premium and intentional
- Lay the foundation for Supabase-backed cloud sync (actual sync is out of scope here)

---

## User Stories

### US-001: Supabase Project Setup
**Description:** As a developer, I need a configured Supabase project so auth services are available.

**Acceptance Criteria:**
- [ ] Supabase project created (or existing project used)
- [ ] `supabase_url` and `supabase_anon_key` stored in `Config/GeneratedSecrets.swift` (gitignored)
- [ ] Apple OAuth provider enabled in Supabase Dashboard
- [ ] Email Magic Link provider enabled in Supabase Dashboard
- [ ] `profiles` table created: `id (uuid, FK → auth.users)`, `email (text, unique)`, `display_name (text)`, `created_at`
- [ ] Row-Level Security enabled on `profiles` (users can only read/write their own row)
- [ ] Admin account `admin@telepace.cc` created manually in Supabase Dashboard (password set there, never in code)

### US-002: Auth Session Manager
**Description:** As a developer, I need a centralized `AuthService` so all views can react to login state.

**Acceptance Criteria:**
- [ ] `AuthService.swift` — `@MainActor final class: ObservableObject`
- [ ] `@Published var session: Session?` — nil means logged out
- [ ] `@Published var isLoading: Bool`
- [ ] `signInWithApple()` async throws
- [ ] `signInWithMagicLink(email: String)` async throws
- [ ] `signOut()` async throws
- [ ] Session persisted across app restarts via Supabase's built-in keychain storage
- [ ] `AuthService` injected as `@EnvironmentObject` from `DayPageApp`
- [ ] Typecheck passes

### US-003: Auth Entry Screen — Dark Aesthetic
**Description:** As a new user, I want to see a beautiful, on-brand login screen so the first impression matches DayPage's premium feel.

**Acceptance Criteria:**
- [ ] Full-screen dark surface: background `#0A0A0A` (near-black)
- [ ] Subtle noise/grain texture overlay (5–8% opacity SVG or PNG asset, tiled)
- [ ] App logotype or wordmark "DayPage" centered in upper third — Space Grotesk Bold, 32pt, `#F5F0E8` (warm off-white)
- [ ] One-line tagline below: Space Grotesk Regular, 15pt, `#6B6B6B`
- [ ] "Continue with Apple" button: SF Symbol `apple.logo`, white label on `#1A1A1A` surface, 1pt border `#2A2A2A`, rounded 14pt, height 54pt
- [ ] "Continue with Email" button: same geometry, label `#A0A0A0`, border `#222222`
- [ ] Buttons separated by 12pt gap; bottom-anchored with safe area padding
- [ ] "Skip for now" text button — 13pt, `#4A4A4A`, below the two main buttons
- [ ] No back button / navigation chrome — this is a modal sheet or root replacement
- [ ] Typecheck passes
- [ ] Verify visually in Simulator (iPhone 17)

### US-004: Apple Sign-In Flow
**Description:** As a user, I want to sign in with my Apple ID so I don't need to remember a password.

**Acceptance Criteria:**
- [ ] Tapping "Continue with Apple" triggers native `ASAuthorizationAppleIDRequest`
- [ ] On success, Supabase `signInWithIdToken` called with Apple identity token
- [ ] Email extracted from Apple credential and stored in `profiles.email` (first sign-in only — Apple may hide it on repeat sign-ins, use stored value)
- [ ] On success, `AuthService.session` updates → app navigates away from auth screen
- [ ] On cancellation, no error shown — silently dismissed
- [ ] On failure, shows inline error message (14pt, `#E05A5A`)
- [ ] `AuthService.isLoading` drives a `ProgressView` overlay during the async call
- [ ] Typecheck passes

### US-005: Email Magic Link Flow
**Description:** As a user, I want to enter my email and receive a magic link so I can log in without a password.

**Acceptance Criteria:**
- [ ] Tapping "Continue with Email" navigates to `EmailAuthView` (push or sheet)
- [ ] `EmailAuthView` has: dark background matching auth screen, large email text field (Inter Regular 17pt, `#F5F0E8` text, `#1E1E1E` fill, 1pt border `#2A2A2A`, rounded 12pt), "Send Magic Link" CTA button (active state: `#F5F0E8` background, `#0A0A0A` label; disabled when field empty)
- [ ] Email validated client-side (basic regex) before enabling button
- [ ] On submit, `AuthService.signInWithMagicLink(email:)` called
- [ ] Success state: field replaced with confirmation message "Check your inbox — a magic link is on its way." (Space Grotesk, 16pt, centered, `#A0A0A0`)
- [ ] Supabase deep link (`daypage://auth/callback`) configured in `Info.plist` URL schemes
- [ ] App handles the deep link in `DayPageApp` → calls Supabase `session` exchange
- [ ] On link tap from Mail app, user is logged in and lands on Today tab
- [ ] Typecheck passes
- [ ] Verify visually in Simulator (iPhone 17)

### US-006: Logged-In State & Profile Header
**Description:** As a logged-in user, I want subtle confirmation of my identity so I feel grounded in my account.

**Acceptance Criteria:**
- [ ] When `AuthService.session != nil`, Today tab shows a small account indicator: circular avatar placeholder (initials from email, 28pt, `#1E1E1E` fill, `#2A2A2A` border) in the navigation bar trailing position
- [ ] Tapping avatar opens `AccountSheet` (bottom sheet): shows email address (14pt, `#6B6B6B`), "Sign Out" button (destructive, `#E05A5A`), dismiss handle
- [ ] Sign out calls `AuthService.signOut()` → session nil → auth screen re-presented
- [ ] Typecheck passes
- [ ] Verify visually in Simulator (iPhone 17)

### US-007: Contextual Sync Prompt (Local → Cloud)
**Description:** As a local user who has been using DayPage without an account, I want a gentle prompt to sync so I understand the value without being forced.

**Acceptance Criteria:**
- [ ] After 3 memo saves (tracked in `UserDefaults`), if user is not logged in, show a subtle banner at top of Today view: "Sync your journal across devices →" (`#1E1E1E` background, `#A0A0A0` text, 13pt, dismissible with swipe)
- [ ] Banner appears at most once per 7 days (cooldown in `UserDefaults`)
- [ ] Tapping banner presents auth screen as a sheet
- [ ] Typecheck passes

---

## Functional Requirements

- **FR-1**: Supabase iOS SDK integrated (via Swift Package Manager: `https://github.com/supabase/supabase-swift`)
- **FR-2**: `email` is the canonical user identifier; Apple Sign-In normalizes to email on first login
- **FR-3**: Sessions persisted in Keychain; app auto-resumes session on launch without re-auth
- **FR-4**: Auth screen presented as full-screen cover over `RootView` when `session == nil` AND user has not tapped "Skip"
- **FR-5**: "Skip" state stored in `UserDefaults` key `authSkipped`; reset on sign-out
- **FR-6**: Deep link scheme `daypage://auth/callback` registered in `Info.plist` and handled in `DayPageApp.onOpenURL`
- **FR-7**: All auth errors surfaced as localized inline messages (no system alerts)
- **FR-8**: No Google Sign-In in this version
- **FR-9**: Admin account (`admin@telepace.cc`) provisioned manually in Supabase Dashboard — credentials never appear in source code or PRD

---

## Non-Goals

- Cloud sync of memos/vault data (separate feature, depends on this)
- Google Sign-In
- Password-based email auth
- User profile editing (display name, avatar upload)
- Account deletion flow
- Web app auth (separate project, same Supabase backend)
- Push notifications tied to auth state

---

## Design Considerations

### Color Palette
| Token | Hex | Usage |
|---|---|---|
| `surface-base` | `#0A0A0A` | Full-screen backgrounds |
| `surface-raised` | `#1A1A1A` | Button fills, card backgrounds |
| `surface-overlay` | `#1E1E1E` | Input fields, avatar fill |
| `border-subtle` | `#2A2A2A` | Button borders, input borders |
| `border-mid` | `#222222` | Secondary button borders |
| `text-primary` | `#F5F0E8` | Headings, primary labels (warm off-white) |
| `text-secondary` | `#A0A0A0` | Body, subheadings |
| `text-muted` | `#6B6B6B` | Tagline, metadata |
| `text-ghost` | `#4A4A4A` | "Skip for now" |
| `error` | `#E05A5A` | Error messages, destructive actions |

### Typography
- **Space Grotesk Bold** — wordmark, section headings
- **Space Grotesk Regular** — tagline, confirmation copy
- **Inter Regular** — input fields, body text
- Both fonts already bundled in the project (`DSFonts.registerAll()`)

### Texture
- Grain overlay: a 200×200px PNG with white noise at 6% opacity, `BlendMode.overlay`, tiled across the full background
- Adds tactility without distracting from content

### Motion
- Auth screen entrance: fade-in 0.4s ease-out
- Button press: scale 0.97, 0.1s spring
- Error message: slide-in from below, 0.2s

---

## Technical Considerations

- **Supabase Swift SDK** added via SPM — only dependency addition in this PR
- `AuthService` lives in `DayPage/Services/AuthService.swift`
- `AuthView`, `EmailAuthView`, `AccountSheet` live in `DayPage/Features/Auth/`
- Deep link handling added to `DayPageApp.swift` `onOpenURL` modifier
- Apple Sign-In entitlement (`com.apple.developer.applesignin`) must be added to the Xcode target
- Supabase URL/key added to `GeneratedSecrets.swift` alongside existing keys — keep the existing `make secrets` or `generate_secrets.sh` pattern
- No new Xcode targets; no Core Data changes; no vault file format changes

---

## Success Metrics

- User can complete Apple Sign-In in under 3 taps from cold launch
- Magic Link email sent within 5 seconds of submission
- Auth screen feels visually cohesive with DayPage's existing dark UI
- Zero regressions in local memo capture (unauthenticated path)
- Session survives app restart without re-auth prompt

---

## Open Questions

- Should the grain texture asset be generated programmatically (SwiftUI `Canvas`) or shipped as a PNG bundle asset? PNG is simpler but adds ~10KB.
- Supabase project — new dedicated project or reuse an existing one? (affects URL/key rotation)
- Should "Skip" users who later install the Web version see a "You were using DayPage locally — sign in to merge your data" flow? (out of scope now, but worth noting)

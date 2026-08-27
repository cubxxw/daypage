# Issue #887 Apple System Actions verification matrix

This checklist complements ADR-0017. Simulator, package, contract, database, and
build gates are automated; rows marked **real device** must be executed on the
matching Apple OS before release. A missing device is a release-evidence blocker,
not permission to weaken or skip the assertion.

## Automated candidate gates

- `swift test --package-path DayPageKit`
- `xcodebuild test -project DayPage.xcodeproj -scheme DayPage` on a current iOS
  Simulator, plus independent DayPageWidget, DayPageWatch, and DayPageMac builds
- `pnpm contracts:test`, `pnpm backend:check`, and `pnpm backend:verify:local`
- an empty-volume Supabase start, Drizzle migration, transactional RLS/RPC tests,
  two-session claim race, native sync probes, and MCP read/write/propose probe
- localization parity, plist/privacy-manifest validation, Dynamic Type, dark mode,
  compact-width, and iPad layout checks
- ordered policy-revision/outbox backfill, terminal-envelope quarantine, policy downgrade
  during a lease, proposal/policy/replacement-decision server-winner adoption,
  pre-revocation account-transition barriers, expired-lease reconciliation against the
  original lease, per-device attempt ordinals, cross-device same-ordinal receipt
  association, client-clock skew, offline expiry, and local-success/remote-receipt-failure
  tests

The candidate is unacceptable if an approved revision/hash differs from the
executed envelope, a tenant boundary is crossed, an Apple side effect is reported
without confirmed or reconciled evidence, or raw private data appears in logs,
cloud receipts, widgets, notifications, Spotlight, or Live Activities.

## Matching-OS and real-device matrix

| Surface | Device / OS | Procedure | Required evidence and result |
|---|---|---|---|
| Calendar | iPhone on iOS 16.1 and iOS 17+ with a writable account | Review one timed and one all-day proposal; cancel one in DayPage, then confirm; edit the saved event externally and attempt undo | iOS 17+ requests write-only access at confirmation; iOS 16.1 requests legacy event access; the exact reviewed fields are saved without a mutable post-approval editor; cancellation has no success receipt; an external edit produces `needsReview` and is not deleted |
| Reminders | iPhone on iOS 16.1 and iOS 17+ | Confirm a reminder whose due date includes nonzero seconds, cancel a second proposal, externally edit the first, then attempt undo | Full reminder access is requested only after confirmation; seconds/subseconds survive creation; exactly one reminder and one receipt exist; external edits produce `needsReview` and are not deleted |
| Contacts | iPhone with iCloud Contacts | Review a prefilled contact, cancel one in DayPage, confirm a second draft, edit it in Contacts, then attempt undo | Access is requested only after confirmation; the exact reviewed fields are saved without a mutable post-approval editor; no address-book scan or contact-notes entitlement exists; raw identifier/snapshot remain device-local; the edited contact is not deleted |
| Notifications | iPhone with notifications not determined, denied, provisional, and allowed | In English and Chinese, confirm time-sensitive and ordinary alerts at each redaction level, including boundary-length/multiline public text; inspect the signed entitlement; deny once in the OS prompt; cancel a scheduled alert | JIT prompt is localized and appears only after confirmation; the signed app contains the time-sensitive entitlement; private content and thread identifiers never enter the locked surface; title-only hides the body; approved public title/body are not rewritten after approval; interruption downgrade is visible; receipt reflects the actual scheduled/cancelled state |
| AlarmKit | iPhone on iOS 26+ | Enable AlarmKit during a confirmed Focus end alert, pause/resume, relaunch, then cancel | AlarmKit is preferred only when authorized; no duplicate UserNotifications request exists; remaining time survives relaunch; reconcile reports the actual surface |
| Location / MapKit | iPhone on iOS 17+ | Preview address and coordinate routes with a 129+ byte multiline label, request one-shot current location, deny once, and open Maps after approval | Route preview needs no location permission for explicit endpoints; the exact approved label reaches Maps without post-approval normalization; one-shot location does not persist raw coordinates to cloud or telemetry; Maps opens only after review |
| Visit automation | iPhone on iOS 17+ with Always authorization | Enable the separate in-product automation switch, background the app, generate repeated visits, disable the switch | Monitoring requires both explicit product opt-in and Always permission; duplicate visits coalesce; disabling stops monitoring even if the OS grant remains |
| Photos / capture | iPhone and iPad with camera; iOS 16.1 and current | Select photos, take a camera image, import a file, scan a document, OCR, draw ink; cancel each surface once; file one artifact to a verified source memo and one to a new memo | Picker does not request full-library access; add-only is JIT; cancelled bytes are removed; deterministic filing is idempotent; source/new memo attachment paths and manifest destination agree |
| Moment | iPhone on current iOS | Add a selected photo, one-shot place, and picker-selected person; crash once after the cleanup intent but before rejection, crash once after rejection, force one protected-data cleanup failure/relaunch, and save once | Draft remains protected and local; the pre-rejection intent is cancelled when no exact rejected decision exists, but an exactly rejected revision retries deletion after relaunch; the manifest remains until its photo is removed; cloud proposal contains only bounded fields and local reference UUIDs, never photo bytes, names, or coordinates |
| HealthKit | physical iPhone with Health data | Confirm “today steps” context, deny once, and repeat with data | Only step-count read access is requested; no write type or broad time window; bounded summary stays local and cloud receives only the approved reference |
| WeatherKit | signed current-iOS device with WeatherKit entitlement | Confirm a current-condition context from an approved one-shot location | Provider response and coordinates remain local; only bounded condition/temperature summary is attached |
| Siri / App Intents | iPhone on iOS 16.1, 17, and 18+ | Discover shortcuts, draft an action, open pending review, start Focus, and invoke widget/control actions while the app is terminated; force one foreground handling failure and retry | Intents remain thin: draft or navigate, never approve/execute; UTF-8 byte limits and iOS availability guards hold; the foreground runtime retains a failed App Group handoff and acknowledges the exact command once after success |
| Spotlight | iPhone on iOS 16.1 and iOS 18+ | Enable indexing, search a public summary, lock the phone, sign out, and disable indexing | No private summary or raw identifier is indexed; locked presentation is redacted; sign-out/disable removes only the user-scoped DayPage domain |
| Widget / Control | iPhone on iOS 16.1, 17, and 18+ | Add the next-action widget, review from deep link, use interactive control where supported, then lock the device | iOS 16 deep-link fallback works; iOS 17 interaction and iOS 18 controls use the same handoff; locked widget exposes only bounded counts/titles |
| Live Activity / Dynamic Island | compatible iPhone on iOS 16.1, 17, 18, and 26 | Start, pause, resume after a delayed online lease, force ActivityKit update failure after alert scheduling, force AlarmKit cancellation failure, relaunch, force one handoff failure/retry, expire, and end from app and system surfaces | One activity per session; a resumed session receives its full approved duration from native application time; alert scheduling succeeds before the visible activity update and is compensating-cancelled when that update fails; failed cancellation remains ambiguous/retryable rather than acknowledged; stale activity is reconciled or ended; locked content is privacy-minimized |
| Watch | paired Apple Watch on watchOS 10+ | Capture on Watch, sync to phone, force raw append, queue-write, and protected-data failures, relaunch, review the resulting memo/proposal, then disconnect and reconnect repeatedly with the same transfer | The phone owns a durable inbox obligation before the Watch source can disappear; memo and transcription-queue failures retain it and retry idempotently; completed transcription is not re-enqueued; content-hash identity and stable timestamps prevent duplicate memos or overwrite; no private action detail leaks to the Watch surface |
| Share bridge (#876) | iPhone with the #876 Share Extension build | Share a screenshot into the App Group inbox, cold-launch DayPage, and retry delivery | The extension writes only a bounded inbox envelope; DayPage consumes it once through the shared bridge; the Vault is never placed in UserDefaults or App Group storage |

## Cross-cutting device passes

- Repeat Review, Action Center, System Access, Capture, and Moment in light and
  dark appearances, portrait/landscape iPad, all accessibility text sizes,
  VoiceOver, Reduce Motion, Reduce Transparency, Increase Contrast, and a locked
  device state.
- For every external mutation, retain a screenshot of the exact review, the Apple
  system result, and the DayPage receipt. Record device model, OS build, app build,
  locale, executor device hash suffix, proposal ID, revision, and payload-hash
  prefix. Never include contact data, coordinates, health samples, photo bytes, or
  raw Apple identifiers in the evidence bundle.
- Before and after execute/undo, hash the isolated Vault's existing raw Markdown
  files. Only an explicitly confirmed capture-filing flow may add an attachment or
  memo through `RawStorage`; unrelated bytes and separators must remain identical.

## Recorded local evidence — 2026-08-27

| Gate | Result |
|---|---|
| `swift test --package-path DayPageKit` | 168 XCTest tests plus 29 Swift Testing tests passed; 3 explicitly live-only Supabase tests skipped because their E2E environment variables were absent |
| `xcodebuild test ... -only-testing:DayPageTests` | 190 XCTest tests plus 357 Swift Testing tests in 40 suites passed on iPhone 17 Pro / iOS 26.5 Simulator; 4 pre-existing Simulator Keychain expectations were recorded as known issues, with no System Actions failure |
| Independent Xcode schemes | DayPageWidget (iOS Simulator), DayPageWatch (watchOS Simulator), and DayPageMac builds succeeded with code signing disabled |
| `pnpm backend:check` | Contracts 51/51, MCP 10/10, focused Web 57/57, Web/MCP typechecks, and edge bundle build passed |
| Fresh disposable local database | All 31 Drizzle migrations applied; `verify-system-actions.sql` and the two-session concurrency verifier passed against isolated ports |
| Resource/static checks | English/Chinese localization parity, shell syntax, all app/widget plist-entitlement-privacy manifests, credential-pattern scan, and `git diff --check` passed |

This evidence does not replace the matching-OS/physical-device rows above. Provisioned
entitlements, real Calendar/Contacts accounts, Health data, WeatherKit, AlarmKit,
lock-screen/Dynamic Island behavior, paired Watch delivery, and accessibility hardware
passes remain release gates.

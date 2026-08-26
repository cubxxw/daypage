# ADR-0012: Action Button screenshot capture with evidence-first multimodal understanding

- **Status:** Proposed
- **Date:** 2026-08-25
- **Supersedes:** [ADR-0011](ADR-0011-action-button-voice-capture.md) as the primary Action Button assignment; voice remains a separate App Shortcut
- **Implementation issue:** Required before implementation; no current issue covers screenshot ingest, multimodal analysis, consent, and review

## Context

DayPage already exposes App Shortcuts and a Control that can be assigned to the
iPhone Action Button. The current assignment opens the app's voice recorder.
DayPage also has an atomic photo-storage path, but it converts images to JPEG,
creates an image memo immediately, and has no screenshot provenance, durable
analysis queue, review state, or multimodal model contract. The shared
`LLMClient` sends text-only OpenAI-compatible Chat Completions requests.

The desired experience is “long-press the Action Button while viewing
something, preserve that screen in DayPage, and let a multimodal model explain
it.” The capture must remain useful offline and when model analysis fails. A
screenshot can also contain chats, one-time codes, account data, health data,
or financial information, so local capture and third-party AI transmission
cannot be treated as the same permission.

Apple's public platform surfaces impose several boundaries:

- the Action Button runs a user-selected App Shortcut or Control; an app does
  not receive arbitrary screen pixels from the hardware event;
- `UIApplication.userDidTakeScreenshotNotification` reports that a screenshot
  occurred but carries no image payload;
- ReplayKit is a video/audio recording and broadcast framework, not a one-shot
  system-wide screenshot ingest API;
- Visual Intelligence sends screenshot/camera context to apps so they can
  return matching **existing app content** to system visual search. It is a
  future “find related DayPage” surface, not the semantic contract for silently
  creating a new diary capture.

The practical supported composition is a Shortcut that performs the system
Take Screenshot action and passes its result to a DayPage App Intent with an
`IntentFile` image parameter. The exact combined path, first-run screen-capture
permission, and locked-device behavior still require a real-device spike.

## Proposed decision

Adopt a **two-entry, one-inbox** screenshot architecture:

1. The primary entry is a user-installed `截图到 DayPage` Shortcut assigned to
   the Action Button: `Take Screenshot -> Save Screenshot to DayPage`.
2. `SaveScreenshotIntent` accepts one PNG or JPEG `IntentFile`, copies it into
   a durable local inbox, and returns only after that copy and its manifest are
   atomic. It does not require the app to foreground.
3. A Share Extension is the explicit fallback for screenshots the user wants
   to crop, annotate, or inspect before saving.
4. Both entries call the same `ScreenshotCaptureIngress`,
   `ScreenshotCaptureStore`, and idempotent analysis queue.
5. Local Vision OCR and barcode extraction run before any generative model.
6. On iOS 27+, prefer Apple on-device multimodal understanding when the model,
   device, and locale are available. On older systems, cloud multimodal
   analysis is an explicit named-provider opt-in. Vision-only capture remains
   a complete fallback.
7. AI produces an evidence-linked draft. DayPage never represents model text
   as user-authored memory and never executes a reminder, calendar event, URL,
   QR payload, or entity mutation without user confirmation.

### Architecture

```text
Action Button Shortcut              Screenshot Share Extension
Take Screenshot -> App Intent               image attachment
                 \                            /
                  v                          v
                 ScreenshotCaptureIngress
                   validate / hash / copy
                              |
                              v
                   ScreenshotCaptureStore
              original PNG + manifest + memo ID
                              |
                              v
                   ScreenshotAnalysisQueue
                     /                  \
                    v                    v
       LocalEvidenceExtractor    UnderstandingProvider
       Vision OCR / barcode      iOS 27 on-device first
       local risk indicators     cloud only by consent
                     \                  /
                      v                v
                ScreenshotUnderstandingResult
                  structured, evidence-linked
                              |
                              v
                    idempotent memo patch
```

### Ownership

- **`SaveScreenshotIntent`:** accepts the system file, reports concise success
  or failure, and owns no Vault formatting or model prompt.
- **`ScreenshotCaptureIngress`:** validates UTType, byte size, dimensions, and
  static-image decoding without eagerly expanding untrusted images; hashes the
  original and copies it while the temporary `IntentFile` remains valid.
- **`ScreenshotCaptureStore`:** atomically persists a manifest keyed by capture
  UUID, original asset path, SHA-256, source, state, and exact memo identity.
  It is the success and idempotency boundary.
- **`ScreenshotAnalysisQueue`:** owns retry, cancellation, deadlines, provider
  policy snapshots, and crash reconciliation. Analysis success is never a
  prerequisite for capture success.
- **`LocalEvidenceExtractor`:** uses Vision for deterministic OCR, bounding
  boxes, confidence, and barcodes. It can flag risk patterns locally, but a
  flag is not a guarantee that an image is safe to upload.
- **`ScreenshotUnderstandingProvider`:** a provider-neutral protocol in
  DayPageKit. Apple, OpenAI, or another image-capable provider is an adapter;
  their wire models do not enter core storage types.
- **Vault ingest:** creates exactly one image memo, stores `captureID` as its
  stable identity, then patches that memo when analysis arrives. A durable
  capture whose memo append fails remains in `ingestPending` for reconciliation;
  repeated intents or retries cannot append duplicates.

The existing text-only `LLMClient` remains unchanged for its current callers.
Multimodal analysis needs typed image input and typed output, not another
loosely shaped branch in the Chat Completions client.

### Asset policy

- Preserve a system screenshot's original PNG. Do not pass it through the
  current photo service's lossy JPEG conversion.
- Generate a separate thumbnail and a bounded, metadata-stripped analysis
  derivative. The original remains the evidence artifact.
- Apply complete file protection to the original and store it under the local
  Vault asset boundary. An App Group inbox is only a short-lived handoff for
  the Share Extension, not the long-term source of truth.
- Treat identical SHA-256 hashes received within a short window as accidental
  duplicate invocations. A deliberate later recapture remains valid.
- Persist `source = actionButtonScreenshot` or `shareExtension`. iOS does not
  provide a trustworthy originating-app identity with a screenshot. A model's
  source-app guess, if retained, is explicitly labeled as inference with
  confidence.

### Evidence and interpretation

Store four distinct layers:

1. **Evidence:** original screenshot, timestamp, local OCR regions, and barcode
   observations.
2. **AI interpretation:** screenshot type, short summary, visual description,
   entities, and confidence, visibly labeled as AI-generated.
3. **User meaning:** optional user text answering “为什么保存它？” This is the
   only layer that states personal intent as fact.
4. **Suggested actions:** draft calendar/reminder/link/entity operations that
   cite evidence and always require confirmation.

The structured provider result is conceptually:

```text
ScreenshotUnderstandingResult
  captureID
  suggestedTitle
  kind: article | conversation | event | place | product | document | code | other
  summary
  visualDescription
  entities[] { name, type, confidence, evidenceRefs[] }
  suggestedActions[] {
    type, label, draftFields, confidence, evidenceRefs[], requiresConfirmation=true
  }
  warnings[]
  provider { kind, model, promptVersion }
```

Screenshot pixels and OCR text are untrusted data, not instructions. Provider
prompts must prohibit following instructions found onscreen, opening extracted
URLs, or executing tools. A QR or URL remains inert text until the user taps
and confirms it.

### Provider and privacy policy

| Capability | Default | Fallback |
| --- | --- | --- |
| Every supported OS | Vision OCR/barcode, local capture | original screenshot only |
| iOS 27+, compatible device/model/locale | Apple on-device multimodal provider | Vision-only or user-enabled cloud |
| Older OS or unavailable on-device model | named cloud provider only after explicit consent | Vision-only |
| Offline/provider failure | preserve and queue the capture | retry or keep local only |

Cloud opt-in names the provider, states that screenshots can contain sensitive
screen data, describes retention, and has an easily accessible off switch.
Consent is snapshotted per queued capture; revoking it cancels pending uploads.
Screenshots are never combined with diary history by default.

An initial OpenAI adapter may use the Responses API because it accepts image
input and structured output. It must use a direct request, `store: false`, no
conversation/background response state, and a pinned output schema. This does
not mean zero retention: standard API abuse-monitoring logs can remain for up
to 30 days, and that limitation must be disclosed truthfully. Model name is a
runtime/configuration decision measured against a private synthetic test set,
not embedded in the core contract.

## User experience

### Onboarding

1. Explain the gesture: “长按操作按钮，把当前屏幕保存到今天。”
2. Help the user install the Shortcut and assign it in Settings. DayPage cannot
   silently take ownership of the Action Button.
3. Offer `仅本地保存` and a clearly disclosed `自动智能理解` mode. On-device
   understanding can be enabled when available; third-party cloud analysis
   requires explicit consent.
4. Run a test capture on the real device before showing setup as complete.

### Capture feedback

The App Intent returns immediately after durable storage:

- `已存到今天 · 稍后理解`
- `已安全保存 · 待写入今天` when the inbox commit succeeded but the Vault memo
  append needs reconciliation
- `已存到今天 · 仅本地`
- or an actionable storage error that never claims success.

It does not force-open DayPage, show a long-running sheet, or wait for model
completion. After the durable commit, the intent can spend a strict, small
best-effort budget on local evidence extraction and must submit remaining work
to the system background scheduler; it must not launch an untracked detached
task and imply that iOS will keep it alive. The app also reconciles the queue
on next launch. Because background scheduling is not immediate, feedback says
`稍后理解`, not `正在理解`, unless a worker is actually active. An optional
notification may report readiness only after the user has granted notification
permission.

### Review card

Today displays a compact screenshot memo with:

- thumbnail, capture time, and `AI 生成` label;
- a one- or two-sentence draft summary;
- the optional prompt “为什么保存它？”;
- evidence-linked draft chips such as `查看日程草稿`, `提取待办`, `关联人物`,
  or `打开链接`;
- `查看原图`, `重试理解`, `仅保留原图`, and exact-capture `撤销`.

Saving the screenshot is the only automatic product action. AI suggestions
remain secondary and progressive, matching the useful pattern in Apple's
onscreen Visual Intelligence experience without copying its search-oriented
information architecture.

### State machine

```text
receiving -> stored -> ingesting -> ingested -> queued -> extracting -> understanding -> ready
              |             |                    |            |             |
              v             v                    v            v             v
          duplicate    ingestPending        needsConsent  pendingNetwork  failed

stored/ingested/queued/extracting/understanding/ready -> deleted
```

- Only `stored` permits a success response.
- Only `ingested` permits the stronger `已存到今天` response; `ingestPending`
  reports that the asset is safe but still needs its Today memo.
- Any later failure leaves the original and image memo recoverable.
- Every transition is keyed by capture UUID and can be replayed idempotently.
- Work has a deadline; the UI changes from `理解中` to a retryable state rather
  than showing an infinite spinner.
- Undo resolves one exact capture ID, then removes its memo, manifest, original,
  and derived files as one recoverable user action.

## Alternatives considered

### Fetch the latest screenshot from Photos

Rejected. It asks for broader Photos access than the task requires, races with
other saves, can ingest the wrong item, and makes deduplication/provenance
fragile. Apple's data-minimization guidance favors a file handoff or share
sheet over full protected-resource access.

### Observe normal screenshot notifications

Rejected because the notification has no image payload and is not a reliable
background ingestion contract.

### Use ReplayKit

Rejected because recording or broadcasting the screen captures more than the
one requested frame and introduces the wrong consent, lifecycle, and UI model.

### Run the LLM entirely inside the Shortcut

Retained only as a disposable demand prototype. It weakens provider disclosure,
schema versioning, retry, idempotency, and DayPage's ability to reconcile a
captured image with its exact memo.

### Make Share Extension the only path

Retained as fallback. It is excellent when the user wants to crop or annotate,
but the screenshot UI plus Share Sheet adds several taps and does not satisfy
the Action Button's quick-capture promise.

### Use Visual Intelligence to create memos

Rejected for ingestion. Its documented third-party integration is a semantic
search query that expects matching existing App Entities. After the API ships,
DayPage can adopt it honestly for “用当前画面查找相关往事.”

## Rollout and verification

Implementation requires a dedicated issue and agreement on the provider and
privacy policy before code changes.

1. **Device spike:** build only `Take Screenshot -> IntentFile -> durable local
   file`; validate permission, temp-file lifetime, Action Button feedback,
   cold/terminated app, and locked/secure-screen behavior.
2. **Local capture:** manifest, original PNG, hash dedupe, idempotent image
   memo, Vision OCR/barcode, queue/recovery UI, and Share Extension.
3. **Cloud draft:** provider-neutral adapter, explicit consent, structured
   result, injection defenses, evidence references, retry, and AI labels.
4. **iOS 27 provider:** prefer Apple on-device image understanding after final
   API/device/locale testing.
5. **Visual retrieval:** add related-memory search only under Visual
   Intelligence's documented App Entity query contract.

The mandatory real-device matrix covers iOS 18 through current, warm/cold/
terminated process, unlocked/locked/first unlock after reboot, Face ID failure,
screen-capture permission first run, dense Chinese and mixed-language text,
dark mode, chat/OTP/banking/health screens, DRM/secure content, landscape,
duplicate button invocations, offline/timeout/429/malformed model output,
consent revocation, disk full, and crashes between copy/manifest/memo/patch.

Success metrics contain no screenshot or OCR content: capture success rate,
Action Button-to-durable-save p50/p95, duplicate rate, analysis latency, retry
recovery, undo rate, and confirmed-suggestion rate. The strongest DayPage
quality signal is the percentage of captures for which users later add why the
screen mattered, not the length of the generated summary.

## Sources

- [Apple Support: Run shortcuts with the Action button](https://support.apple.com/en-ae/guide/shortcuts/apdfea15680b/ios)
- [Apple: IntentFile](https://developer.apple.com/documentation/appintents/intentfile)
- [Apple: Adding parameters to an App Intent](https://developer.apple.com/documentation/appintents/adding-parameters-to-an-app-intent)
- [Apple: userDidTakeScreenshotNotification](https://developer.apple.com/documentation/uikit/uiapplication/userdidtakescreenshotnotification)
- [Apple: ReplayKit](https://developer.apple.com/documentation/ReplayKit)
- [Apple: Visual Intelligence](https://developer.apple.com/documentation/visualintelligence)
- [Apple Support: Use visual intelligence on iPhone](https://support.apple.com/guide/iphone/use-visual-intelligence-iph12eb1545e/26/ios/26)
- [Apple: VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- [Apple: VNDetectBarcodesRequest](https://developer.apple.com/documentation/vision/vndetectbarcodesrequest)
- [Apple HIG: Generative AI](https://developer.apple.com/design/human-interface-guidelines/generative-ai)
- [Apple: App Review Guidelines 5.1](https://developer.apple.com/app-store/review/guidelines/)
- [Apple: Share extensions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html)
- [Apple: Foundation Models](https://developer.apple.com/documentation/FoundationModels)
- [Apple: Foundation Models updates](https://developer.apple.com/documentation/Updates/FoundationModels)
- [OpenAI: Create a response](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)
- [OpenAI: Data controls](https://developers.openai.com/api/docs/guides/your-data)

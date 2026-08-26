# ADR-0011: Native Action Button voice capture with durable local handoff

- **Status:** Superseded by [ADR-0012](ADR-0012-action-button-screenshot-capture.md) as the primary Action Button assignment; retained as a possible separate voice shortcut
- **Date:** 2026-08-25
- **Predecessor issue:** [#281](https://github.com/getyak/daypage/issues/281)
- **Implementation issue:** Required before implementation; #281 explicitly
  excluded Live Activities and background capture.

## Context

DayPage currently exposes `StartRecordingIntent` through Siri, Shortcuts,
widgets, Control Center, and the iPhone Action Button. The intent foregrounds
the app, deep-links to Today, opens the recording sheet, and only then starts
the microphone. This is discoverable but is not a lock-screen capture flow.

The desired experience is “long-press the Action Button, speak, and have the
transcript arrive in DayPage.” The public Action Button integration does not
provide third-party apps with raw button-down, button-up, or hold-duration
callbacks. A press-and-hold invokes an App Shortcut or Control once. Therefore
“record while physically held and stop on release” cannot be implemented as a
third-party push-to-talk gesture.

iOS 18 adds `AudioRecordingIntent` and Action-Button-assignable Controls.
Apple requires an audio-recording intent that starts recording to display and
maintain a Live Activity; otherwise the system stops the recording. iOS 26 adds
the on-device `SpeechAnalyzer` / `SpeechTranscriber` stack.

## Proposed decision

### Interaction contract

Use an iOS 18+ `ControlWidgetToggle` as the primary Action Button surface:

1. first Action Button invocation starts recording;
2. second invocation stops and saves;
3. optional voice-activity detection can stop after configurable silence;
4. a Live Activity provides visible recording state and a Stop fallback.

The UI and onboarding must call this “press once to start, press again to
stop.” It must not imply that releasing the hardware button stops recording.
The existing foreground-opening `StartRecordingIntent` remains the iOS 16–17
fallback and a deliberate “open recorder” shortcut.

### Architecture

```text
Action Button / Control / Shortcut
                |
                v
     SetVoiceCaptureIntent
  (SetValueIntent + AudioRecordingIntent)
                |
                v
      VoiceCaptureCoordinator
       /        |         \
      v         v          v
AVAudioRecorder  CaptureStore  VoiceCaptureActivity
      |              |              |
      +--------------+--------------+
                     v
          TranscriptionPipeline
          /                    \
 iOS 26 SpeechAnalyzer     iOS 18–25 fallback
                     |
                     v
        idempotent RawStorage append/update
```

- **Intent layer:** validates readiness and expresses the requested on/off
  value. It contains no recorder, transcription, or Vault business logic.
- **`VoiceCaptureCoordinator`:** the single owner of audio-session and capture
  state. The foreground recorder UI and system intent call the same coordinator
  so two recorders cannot race for the microphone.
- **`CaptureStore`:** atomically persists a minimal manifest keyed by capture
  UUID before audio starts. It contains status, timestamps, source, locale, and
  relative audio path, but never a transcript in shared defaults.
- **Live Activity:** displays only “DayPage 正在录音,” elapsed time, and Stop.
  It never shows diary text, filename, location, or live transcript on the
  lock screen.
- **`TranscriptionPipeline`:** owns locale/model selection and provider
  fallback. Capture success never depends on transcription success.
- **Vault ingest:** saves audio first, appends one voice memo exactly once using
  capture UUID as the idempotency key, then patches that attachment when a
  transcript arrives.

### State machine

```text
idle
  -> starting
  -> recording
  -> finalizing
  -> ingesting
  -> transcribing
  -> saved

starting/recording/finalizing/ingesting/transcribing
  -> pending_retry | failed | interrupted | cancelled
```

Rules:

- `starting` rejects duplicate starts and has a target of less than 300 ms from
  intent invocation to haptic/system recording indication on a warm stack.
- `recording` owns one capture UUID, one audio file, and one Live Activity.
- a stop during `starting` records a cancellation request; it must not leave an
  unattended recorder after an asynchronous audio-session startup.
- an interruption finalizes the current partial take and marks its reason. It
  does not silently resume after a call.
- `ingesting` preserves the audio and appends the pending voice memo before
  transcription begins; recognition failure can never erase a valid capture.
- app relaunch reconciles manifests, active Live Activities, and orphan audio.
  No valid audio is deleted automatically.
- every terminal transition reloads the Control so its toggle cannot remain
  visually stale.

### Start transaction

1. Verify microphone permission is already granted, Live Activities are
   enabled, protected storage is accessible, and no other capture is active.
2. Allocate capture UUID and atomically persist `.starting` in app-owned
   storage; mirror only non-sensitive status to the existing App Group.
3. Request the Live Activity.
4. Configure `AVAudioSession` and start an `AVAudioRecorder` file under
   `vault/raw/assets/`.
5. Persist `.recording(startedAt:)`, update the Activity, and reload the
   Control.
6. If any step fails, unwind in reverse order and surface a concise intent
   dialog. Never report success before the recorder actually starts.

The app adds `audio` to `UIBackgroundModes` only with this implementation and
uses it solely while a user-visible recording is active.

### Stop and ingest transaction

1. Atomically claim the active capture for finalization so repeated Stop
   invocations are idempotent.
2. Stop the recorder and audio session; preserve the finalized `.m4a` even if
   every later step fails.
3. Append a voice memo immediately with attachment status `.pending`.
4. End the recording Live Activity immediately; do not leave “recording” visible
   during minutes of retry work.
5. Transcribe locally when possible and patch the exact attachment by capture
   UUID/path. On failure, retain `.pending_retry`/`.failed` and the existing
   retry UI; never append a duplicate memo.

This reuses the existing `VoiceAttachmentQueue` writeback behavior after that
queue accepts a capture UUID as its stable identity. Transcript text belongs in
the audio attachment, consistent with existing voice memos; the audio file
remains the source artifact.

### Transcription policy

| OS / capability | Default | Fallback |
| --- | --- | --- |
| iOS 26+, supported locale/model installed | `SpeechAnalyzer` + `SpeechTranscriber`, on-device | explicit enhanced/server option |
| iOS 26+, model downloadable | preserve audio, queue model installation, then on-device | explicit enhanced/server option |
| iOS 18–25, `SFSpeechRecognizer.supportsOnDeviceRecognition` | on-device `SFSpeechURLRecognitionRequest` | user-approved Apple network or DayPage provider |
| unsupported locale/offline provider | save audio + pending/failed transcript | retry from app |

Locale support is probed at runtime. On iOS 26 the app reserves/downloads the
selected model during onboarding, not during the first lock-screen invocation.
Server transcription never receives raw audio silently; it is a named opt-in
with encrypted transport, bounded retention, deletion, and visible provider
state.

### Permissions and lock-screen behavior

Microphone and Speech permissions are requested separately in foreground
onboarding. The Action Button setup screen verifies permission, model, Live
Activity availability, and Control binding before telling the user the feature
is ready. An intent invoked without readiness returns “打开 DayPage 完成语音设置”
instead of attempting a lock-screen permission prompt.

The start/stop intent uses the least restrictive authentication policy that can
safely operate while locked, because the hardware gesture is explicit. Any UI
that reveals, deletes, or edits transcript content requires normal app access.
A device that has rebooted but has not yet been unlocked fails closed rather
than weakening Vault file protection.

## Alternatives considered

### Record only while the Action Button is physically held

Rejected because the public integration supplies one intent/control invocation,
not raw hardware down/up events. A release-to-stop promise would be false.

### Continue foregrounding the app

Retained only as a compatibility fallback. It adds launch/navigation/sheet
latency, fails the lock-screen use case, and makes the Action Button little more
than a deep link.

### A personal Shortcut that records, transcribes, and POSTs to DayPage

Useful as a zero-native-code demand prototype. It validates frequency and
preferred auto-stop behavior but has setup friction, weaker state/recovery, and
less predictable locked-device behavior than an app-owned coordinator.

### Default server transcription

Rejected. The newest supported systems can transcribe on-device, and a diary's
raw voice should not leave the device merely because a hardware shortcut was
used.

## Rollout and verification

Implementation is split so every stage is independently shippable:

1. **Shortcut prototype:** validate twice-press versus silence-auto-stop and
   measure real user take length.
2. **iOS 18 native capture:** toggle intent, coordinator, durable manifest,
   audio background mode, Live Activity, direct voice-memo ingest.
3. **iOS 26 local transcript:** SpeechAnalyzer model onboarding and runtime
   locale probing; keep the iOS 18–25 fallback.
4. **Hardening:** interruption, crash/orphan recovery, model/network retry,
   accessibility, privacy copy, and analytics without content.

Required device matrix includes cold/warm app process, locked/unlocked screen,
Face ID success/failure, first unlock after reboot, AirPods/Bluetooth route,
incoming call/alarm/Siri interruption, airplane mode, model absent/downloading,
network loss during fallback, rapid double invocation, and app termination.

Success metrics are start latency p50/p95, capture completion rate, orphan rate,
duplicate-memo rate (target zero), transcription latency, retry recovery rate,
and accidental starts. No metric records audio or transcript content.

## Sources

- [Apple: Hardware interactions](https://developer.apple.com/documentation/appintents/hardware-interactions)
- [Apple: AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
- [Apple HIG: Controls](https://developer.apple.com/design/human-interface-guidelines/controls)
- [Apple HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)
- [Apple: SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/)

# DayPage

DayPage is an iOS journaling app for capturing raw daily signals and turning them into structured reflection.

Instead of writing polished diary entries up front, you quickly dump text, voice, photos, location, and context throughout the day. DayPage stores that raw material locally, then uses AI to compile it into a readable Daily Page and a lightweight personal knowledge network.

## Why DayPage

DayPage is built for people who think in fragments while moving through the day, especially nomads and digital nomads.

It helps you:

- capture thoughts before they disappear
- keep text, voice, photos, weather, and place context together
- review a compiled daily narrative instead of a pile of notes
- accumulate entity pages and long-term memory over time
- revisit prior days through archive and "On This Day" flows

## Core Experience

The product flow is:

`raw capture -> AI compilation -> daily page -> entity pages -> graph (post-MVP)`

### 1. Capture raw moments during the day

Users can log:

- text notes
- voice recordings with transcript support
- photos with extracted metadata
- location snapshots and passive visit drafts
- contextual metadata like weather and device info

Raw entries are stored as Markdown files with YAML front matter under the local vault.

### 2. Compile the day with AI

DayPage can compile a day's raw memos into a structured Daily Page using DashScope's OpenAI-compatible API.

The compilation step produces:

- a Daily Page in Markdown
- entity update instructions for people, places, and themes
- a refreshed short-term memory cache (`hot.md`)
- compilation logs

### 3. Explore the result

Users can then:

- read the compiled Daily Page
- browse past entries in the archive
- inspect entity pages generated from repeated themes and places
- revisit relevant memories via On This Day

## Feature Highlights

### Today

- fast input bar for quick capture
- optional newer and legacy input/recording experiences
- memo timeline with cards for text, voice, photo, and location content
- sticky compile call-to-action when enough content exists
- banners for API status, background compilation results, and queued work
- passive location arrival drafts for lightweight place confirmation

### Daily Page

- compiled narrative view with digest and timeline modes
- hero cover image support from the best photo of the day
- metadata editing and manual recompile actions
- links into related entity pages

### Archive

- calendar and list exploration modes
- density heatmap for daily activity
- monthly summaries and system status
- day detail drill-down into raw and compiled content
- search across stored content

### Knowledge Layer

- entity pages for recurring places, people, and themes
- hot cache for short-term AI memory
- graph tab reserved for post-MVP knowledge network work

## Storage Model

DayPage uses the file system instead of Core Data or SwiftData.

Key paths inside the vault:

- `vault/raw/YYYY-MM-DD.md`: raw memos for a day
- `vault/raw/assets/`: audio and photo attachments
- `vault/wiki/daily/YYYY-MM-DD.md`: compiled Daily Pages
- `vault/wiki/hot.md`: short-term memory cache
- `vault/wiki/log.md`: compilation log

Raw memo files use YAML front matter plus Markdown body content. Multiple memos in one day file are separated by `\n\n---\n\n`.

## Tech Stack

- iOS 16+
- Swift 5
- SwiftUI
- ObservableObject + `@Published` + `@StateObject`
- file-based persistence with Markdown and YAML front matter
- AVFoundation for audio recording
- PhotosUI / PHPicker for images
- CoreLocation for location and visit monitoring
- OpenWeatherMap for weather context
- OpenAI Whisper API for speech-to-text
- Aliyun DashScope for Daily Page compilation
- BGTaskScheduler for nightly background compilation

## Project Structure

```text
DayPage/
  App/              App entry, root navigation, font registration
  Config/           Generated secrets (gitignored)
  DesignSystem/     Colors, typography, spacing, components
  Features/
    Today/          Raw capture flow
    Daily/          Compiled Daily Page UI
    Archive/        Calendar, list, search, day detail
    Entity/         Entity pages
    Graph/          Post-MVP placeholder
    Onboarding/     First-run setup
    Settings/       API keys, permissions, appearance, export
  Models/           Memo parsing and shared models
  Services/         Storage, AI, location, weather, voice, photos, logging
  Storage/          Vault bootstrap and raw file helpers
```

## Configuration

Secrets are generated into `DayPage/Config/GeneratedSecrets.swift` and should not be committed.

The app expects API keys for:

- DashScope: Daily Page compilation
- OpenAI Whisper: voice transcription
- OpenWeatherMap: weather lookup

Never hardcode secrets directly in source files.

## Running the App

1. Open the Xcode project for `DayPage`.
2. Generate `GeneratedSecrets.swift` from your local environment.
3. Select the `DayPage` scheme.
4. Build and run on an iOS 16+ simulator or device.

## Development Notes

- SwiftUI is the primary UI framework.
- The app intentionally avoids external dependencies.
- The graph experience is not implemented yet.
- Design references are checked into `design/stitch/` and should be read locally when implementing UI.

## Testing

The repository includes Swift tests and script-based validation helpers.

Before considering a change complete:

1. Build the `DayPage` scheme.
2. Run available tests.
3. For storage changes, inspect generated Markdown in the app vault.
4. For UI changes, verify behavior in Simulator.

## Status

DayPage is an actively evolving iOS product focused on turning messy daily inputs into a usable personal memory system.

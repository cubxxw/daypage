#!/usr/bin/env bash
set -euo pipefail

# Capture trustworthy visual baselines from a disposable Simulator.
#
# Unlike Maestro's iOS launchApp handler, simctl forwards process arguments.
# This lets each filename truthfully represent its locale, theme, data state,
# and selected tab. Empty states are captured before the deterministic memo
# fixtures are seeded so the two groups cannot contaminate each other.

: "${SIMULATOR_UDID:?SIMULATOR_UDID must name the disposable audit simulator}"

app_path="${1:?usage: capture_ios_visual_baselines.sh /path/to/DayPage.app [output-dir]}"
output_dir="${2:-maestro-results/baseline}"
bundle_id="com.daypage.app"
settle_seconds="${DAYPAGE_VISUAL_SETTLE_SECONDS:-6}"

simctl() {
  if [[ -n "${DAYPAGE_SIMCTL_SET:-}" ]]; then
    xcrun simctl --set "$DAYPAGE_SIMCTL_SET" "$@"
  else
    xcrun simctl "$@"
  fi
}

if [[ ! -d "$app_path" ]]; then
  echo "DayPage app bundle not found: $app_path" >&2
  exit 1
fi

mkdir -p "$output_dir"

# Start from one known-empty application container. The UI-test job owns this
# freshly-created Simulator, so reinstalling the test app cannot touch user data.
simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
simctl bootstatus "$SIMULATOR_UDID" -b
simctl terminate "$SIMULATOR_UDID" "$bundle_id" >/dev/null 2>&1 || true
simctl uninstall "$SIMULATOR_UDID" "$bundle_id" >/dev/null 2>&1 || true
simctl install "$SIMULATOR_UDID" "$app_path"
# CoreSimulator's cfprefsd can retain a removed app's cached domain across
# uninstall/reinstall inside a long-lived device. Clear only the sample flag
# whose stale `true` value would make a clean vault claim “Ready”.
simctl spawn "$SIMULATOR_UDID" \
  defaults delete "$bundle_id" hasSeededSamples >/dev/null 2>&1 || true
simctl status_bar "$SIMULATOR_UDID" override \
  --time 9:41 \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularBars 4 >/dev/null 2>&1 || true

capture() {
  local language="$1"
  local locale="$2"
  local language_suffix="$3"
  local theme="$4"
  local fixture="$5"
  local tab="$6"

  # CoreSimulator can recycle an otherwise-idle CI device between launches.
  # Reassert boot state for every capture so one host-level shutdown cannot
  # leave a partially named baseline matrix behind.
  simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  simctl bootstatus "$SIMULATOR_UDID" -b >/dev/null
  simctl terminate "$SIMULATOR_UDID" "$bundle_id" >/dev/null 2>&1 || true
  simctl spawn "$SIMULATOR_UDID" \
    defaults write "$bundle_id" AppleLanguages -array "$language"
  simctl spawn "$SIMULATOR_UDID" \
    defaults write "$bundle_id" AppleLocale "$locale"
  simctl spawn "$SIMULATOR_UDID" \
    defaults write "$bundle_id" hasOnboarded -bool YES
  simctl spawn "$SIMULATOR_UDID" \
    defaults write "$bundle_id" hasSeenWelcome -bool YES
  simctl spawn "$SIMULATOR_UDID" \
    defaults write "$bundle_id" authSkipped -bool YES
  simctl spawn "$SIMULATOR_UDID" \
    defaults write "$bundle_id" settings.hasRequestedNotifications -bool YES
  simctl spawn "$SIMULATOR_UDID" \
    defaults write "$bundle_id" inputBarTutorialCompleted -bool YES
  local args=(
    -AppleLanguages "($language)"
    -AppleLocale "$locale"
    -hasOnboarded YES
    -hasSeenWelcome YES
    -authSkipped YES
    -settings.hasRequestedNotifications YES
    -inputBarTutorialCompleted YES
    -qaSkipNotificationPrompt YES
    -qaForceLocalVault YES
    -qaDisableAutoSampleSeed YES
    -forceTheme "$theme"
    -qaSelectedTab "$tab"
  )

  if [[ "$fixture" == "memos" ]]; then
    args+=( -qaSeedTodayMemos YES )
    if [[ "$tab" == "graph" ]]; then
      args+=( -qaGraphFixtures YES )
    fi
  fi

  simctl launch --terminate-running-process \
    "$SIMULATOR_UDID" "$bundle_id" "${args[@]}" >/dev/null
  sleep "$settle_seconds"

  local path="$output_dir/${tab}_${theme}_${fixture}_${language_suffix}.png"
  simctl io "$SIMULATOR_UDID" screenshot "$path" >/dev/null
  test -s "$path"
  echo "Captured $path"
}

# Empty must remain first: the memo fixture is intentionally persistent and
# idempotent so Archive and Graph consume the same raw-vault evidence as Today.
for fixture in empty memos; do
  for language_spec in "en|en_US|en" "zh-Hans|zh_CN|zh"; do
    IFS='|' read -r language locale language_suffix <<< "$language_spec"
    for theme in light dark; do
      for tab in today archive graph; do
        capture "$language" "$locale" "$language_suffix" "$theme" "$fixture" "$tab"
      done
    done
  done
done

count=$(find "$output_dir" -maxdepth 1 -name '*.png' -type f | wc -l | tr -d ' ')
if [[ "$count" != "24" ]]; then
  echo "Expected 24 visual baselines, found $count" >&2
  exit 1
fi

echo "Captured 24 isolated DayPage visual baselines."

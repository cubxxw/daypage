#!/usr/bin/env bash
# check_localization_parity.sh
#
# Verifies that en.lproj and zh-Hans.lproj Localizable.strings declare the
# SAME set of keys. A key present in one locale but missing in the other makes
# the missing locale fall back to rendering the raw key string in the UI
# (e.g. the timeline showed `today.section.earlier` instead of "EARLIER").
#
# Exit codes:
#   0 — both locales declare an identical key set
#   1 — drift detected (missing keys are printed per side)
#   2 — a strings file is missing or unreadable
#
# Usage: scripts/check_localization_parity.sh
# Run from the repository root (the script resolves paths relative to itself).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EN="$REPO_ROOT/DayPage/Resources/en.lproj/Localizable.strings"
ZH="$REPO_ROOT/DayPage/Resources/zh-Hans.lproj/Localizable.strings"
EN_INFO="$REPO_ROOT/DayPage/Resources/en.lproj/InfoPlist.strings"
ZH_INFO="$REPO_ROOT/DayPage/Resources/zh-Hans.lproj/InfoPlist.strings"
APP_INFO="$REPO_ROOT/DayPage/App/Info.plist"
APP_ENTITLEMENTS="$REPO_ROOT/DayPage/App/DayPage.entitlements"

for f in "$EN" "$ZH" "$EN_INFO" "$ZH_INFO" "$APP_INFO" "$APP_ENTITLEMENTS"; do
  if [ ! -r "$f" ]; then
    echo "::error::Localizable.strings not found or unreadable: $f"
    exit 2
  fi
done

# Extract the quoted key at the start of each `"key" = "value";` line.
# Matches the same convention the rest of the repo uses (see ci.yml secrets-audit).
extract_keys() {
  grep -oE '^"[^"]+"' "$1" | sort -u
}

EN_KEYS="$(extract_keys "$EN")"
ZH_KEYS="$(extract_keys "$ZH")"
EN_INFO_KEYS="$(extract_keys "$EN_INFO")"
ZH_INFO_KEYS="$(extract_keys "$ZH_INFO")"

MISSING_IN_EN="$(comm -13 <(echo "$EN_KEYS") <(echo "$ZH_KEYS"))"
MISSING_IN_ZH="$(comm -23 <(echo "$EN_KEYS") <(echo "$ZH_KEYS"))"
MISSING_INFO_IN_EN="$(comm -13 <(echo "$EN_INFO_KEYS") <(echo "$ZH_INFO_KEYS"))"
MISSING_INFO_IN_ZH="$(comm -23 <(echo "$EN_INFO_KEYS") <(echo "$ZH_INFO_KEYS"))"
PLIST_USAGE_KEYS="$(grep -oE '<key>NS[^<]*UsageDescription</key>' "$APP_INFO" | sed -E 's#</?key>##g' | sort -u)"
EN_INFO_BARE_KEYS="$(echo "$EN_INFO_KEYS" | tr -d '"')"
ZH_INFO_BARE_KEYS="$(echo "$ZH_INFO_KEYS" | tr -d '"')"
MISSING_USAGE_IN_EN="$(comm -23 <(echo "$PLIST_USAGE_KEYS") <(echo "$EN_INFO_BARE_KEYS"))"
MISSING_USAGE_IN_ZH="$(comm -23 <(echo "$PLIST_USAGE_KEYS") <(echo "$ZH_INFO_BARE_KEYS"))"

FAIL=0

# App Store Connect requires both HealthKit purpose strings whenever the app
# carries the HealthKit entitlement, even when the current feature is read-only.
if grep -q '<key>com.apple.developer.healthkit</key>' "$APP_ENTITLEMENTS"; then
  for key in NSHealthShareUsageDescription NSHealthUpdateUsageDescription; do
    if ! grep -q "<key>$key</key>" "$APP_INFO"; then
      echo "::error::HealthKit entitlement requires $key in DayPage/App/Info.plist"
      FAIL=1
    fi
  done
fi

if [ -n "$MISSING_IN_EN" ]; then
  echo "::error::Keys present in zh-Hans but MISSING in en.lproj (English UI will show raw keys):"
  echo "$MISSING_IN_EN" | sed 's/^/  - /'
  FAIL=1
fi

if [ -n "$MISSING_IN_ZH" ]; then
  echo "::error::Keys present in en but MISSING in zh-Hans.lproj (Chinese UI will show raw keys):"
  echo "$MISSING_IN_ZH" | sed 's/^/  - /'
  FAIL=1
fi

if [ -n "$MISSING_INFO_IN_EN" ]; then
  echo "::error::InfoPlist.strings keys present in zh-Hans but missing in English:"
  echo "$MISSING_INFO_IN_EN" | sed 's/^/  - /'
  FAIL=1
fi

if [ -n "$MISSING_INFO_IN_ZH" ]; then
  echo "::error::InfoPlist.strings keys present in English but missing in zh-Hans:"
  echo "$MISSING_INFO_IN_ZH" | sed 's/^/  - /'
  FAIL=1
fi

if [ -n "$MISSING_USAGE_IN_EN" ]; then
  echo "::error::Info.plist usage descriptions missing from English InfoPlist.strings:"
  echo "$MISSING_USAGE_IN_EN" | sed 's/^/  - /'
  FAIL=1
fi

if [ -n "$MISSING_USAGE_IN_ZH" ]; then
  echo "::error::Info.plist usage descriptions missing from zh-Hans InfoPlist.strings:"
  echo "$MISSING_USAGE_IN_ZH" | sed 's/^/  - /'
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Localization parity check FAILED. Add the missing keys to reach parity."
  exit 1
fi

# App Store Connect rejects App Intent metadata containing the Apple name
# (error 90626). Keep product-trademark wording out of all quoted metadata in
# the intent source so the failure is caught before an otherwise valid upload.
RESTRICTED_INTENT_METADATA="$(grep -nEhi '"[^"]*[Aa][Pp][Pp][Ll][Ee][^"]*"' "$REPO_ROOT"/DayPage/Intents/*.swift || true)"
if [ -n "$RESTRICTED_INTENT_METADATA" ]; then
  echo "::error::App Intent metadata contains the restricted word 'Apple':"
  echo "$RESTRICTED_INTENT_METADATA" | sed 's/^/  - /'
  exit 1
fi

EN_COUNT="$(echo "$EN_KEYS" | grep -c '^"' || true)"
INFO_COUNT="$(echo "$EN_INFO_KEYS" | grep -c '^"' || true)"
echo "✅ Localization parity OK — Localizable.strings: $EN_COUNT keys; InfoPlist.strings: $INFO_COUNT usage keys per locale."

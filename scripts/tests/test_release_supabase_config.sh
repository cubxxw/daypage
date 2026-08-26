#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/daypage-release-config.XXXXXX")
trap 'rm -rf "${TEST_ROOT:?}"' EXIT

GENERATOR="${REPO_ROOT}/scripts/generate_secrets.sh"
VALIDATOR="${REPO_ROOT}/scripts/ci/validate_release_supabase_config.sh"
PUBLIC_KEY="sb_publishable_1234567890abcdefghijklmnop"
LEGACY_ANON_KEY="eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.signature"
LEGACY_SERVICE_KEY="eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.signature"
SENTRY_DSN="https://0123456789abcdef0123456789abcdef@o0.ingest.sentry.io/123456"

write_env() {
    local root="$1"
    local key_line="$2"
    mkdir -p "${root}"
    printf 'SUPABASE_URL=https://project-ref.supabase.co\n%s\nSENTRY_DSN=%s\n' \
        "${key_line}" "${SENTRY_DSN}" > "${root}/.env"
}

assert_generated_sentry_value() {
    local root="$1"
    local expected="$2"
    grep -Fq "static let sentryDSN: String = \"${expected}\"" \
        "${root}/DayPage/Config/GeneratedSecrets.swift"
}

assert_generated_value() {
    local root="$1"
    local expected="$2"
    grep -Fq "static let supabasePublishableKey: String = \"${expected}\"" \
        "${root}/DayPage/Config/GeneratedSecrets.swift"
}

# Fresh checkouts still generate a compiling placeholder without .env.
empty_root="${TEST_ROOT}/empty"
mkdir -p "${empty_root}"
SRCROOT="${empty_root}" bash "${GENERATOR}" >/dev/null
assert_generated_value "${empty_root}" ""
assert_generated_sentry_value "${empty_root}" ""

# New publishable key is embedded as required public mobile configuration.
publishable_root="${TEST_ROOT}/publishable"
write_env "${publishable_root}" "SUPABASE_PUBLISHABLE_KEY=${PUBLIC_KEY}"
SRCROOT="${publishable_root}" bash "${GENERATOR}" >/dev/null
assert_generated_value "${publishable_root}" "${PUBLIC_KEY}"
assert_generated_sentry_value "${publishable_root}" "${SENTRY_DSN}"
bash "${VALIDATOR}" "${publishable_root}/.env" >/dev/null

# Existing release environments using the legacy anon key keep working.
legacy_root="${TEST_ROOT}/legacy"
write_env "${legacy_root}" "SUPABASE_ANON_KEY=${LEGACY_ANON_KEY}"
SRCROOT="${legacy_root}" bash "${GENERATOR}" >/dev/null
assert_generated_value "${legacy_root}" "${LEGACY_ANON_KEY}"
bash "${VALIDATOR}" "${legacy_root}/.env" >/dev/null

# The new variable wins while both values exist during migration.
priority_root="${TEST_ROOT}/priority"
mkdir -p "${priority_root}"
printf 'SUPABASE_URL=https://project-ref.supabase.co\nSUPABASE_PUBLISHABLE_KEY=%s\nSUPABASE_ANON_KEY=%s\nSENTRY_DSN=%s\n' \
    "${PUBLIC_KEY}" "${LEGACY_ANON_KEY}" "${SENTRY_DSN}" > "${priority_root}/.env"
SRCROOT="${priority_root}" bash "${GENERATOR}" >/dev/null
assert_generated_value "${priority_root}" "${PUBLIC_KEY}"

# Release must stop before archive for empty, placeholder, or privileged keys.
invalid_root="${TEST_ROOT}/invalid"
write_env "${invalid_root}" "SUPABASE_PUBLISHABLE_KEY=sb_secret_1234567890abcdefghijklmnop"
if bash "${VALIDATOR}" "${invalid_root}/.env" >/dev/null 2>&1; then
    echo "validator accepted an sb_secret key" >&2
    exit 1
fi

write_env "${invalid_root}" "SUPABASE_PUBLISHABLE_KEY=sb_publishable_replace-me-value"
if bash "${VALIDATOR}" "${invalid_root}/.env" >/dev/null 2>&1; then
    echo "validator accepted a placeholder publishable key" >&2
    exit 1
fi

write_env "${invalid_root}" "SUPABASE_ANON_KEY=${LEGACY_SERVICE_KEY}"
if bash "${VALIDATOR}" "${invalid_root}/.env" >/dev/null 2>&1; then
    echo "validator accepted a service_role key" >&2
    exit 1
fi

printf 'SUPABASE_URL=https://replace-me.supabase.co\nSUPABASE_PUBLISHABLE_KEY=%s\nSENTRY_DSN=%s\n' \
    "${PUBLIC_KEY}" "${SENTRY_DSN}" > "${invalid_root}/.env"
if bash "${VALIDATOR}" "${invalid_root}/.env" >/dev/null 2>&1; then
    echo "validator accepted a placeholder URL" >&2
    exit 1
fi

printf 'SUPABASE_URL=https://project-ref.supabase.co\nSUPABASE_PUBLISHABLE_KEY=%s\n' \
    "${PUBLIC_KEY}" > "${invalid_root}/.env"
if bash "${VALIDATOR}" "${invalid_root}/.env" >/dev/null 2>&1; then
    echo "validator accepted a release without Sentry diagnostics" >&2
    exit 1
fi

printf 'SUPABASE_URL=https://project-ref.supabase.co\nSUPABASE_PUBLISHABLE_KEY=%s\nSENTRY_DSN=https://invalid.example/abc\n' \
    "${PUBLIC_KEY}" > "${invalid_root}/.env"
if bash "${VALIDATOR}" "${invalid_root}/.env" >/dev/null 2>&1; then
    echo "validator accepted a malformed Sentry DSN" >&2
    exit 1
fi

echo "PASS: release Supabase/Sentry configuration generation and validation"

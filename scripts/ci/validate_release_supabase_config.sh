#!/usr/bin/env bash
# Fail a release before archive when its public Supabase/Sentry client
# configuration is missing, placeholder-only, malformed, or privileged.

set -euo pipefail

ENV_FILE="${1:-.env}"

fail() {
    echo "[release-config] ERROR: $1" >&2
    exit 1
}

read_env_value() {
    local key="$1"
    local value=""
    if [[ -f "${ENV_FILE}" ]]; then
        value=$(awk -v key="${key}" '
            index($0, key "=") == 1 {
                value = substr($0, length(key) + 2)
                sub(/\r$/, "", value)
                print value
                exit
            }
        ' "${ENV_FILE}")
    fi
    printf '%s' "${value}"
}

[[ -f "${ENV_FILE}" ]] || fail "release environment file is missing"
command -v ruby >/dev/null 2>&1 || fail "ruby is required to validate release configuration"

supabase_url=$(read_env_value SUPABASE_URL)
publishable_key=$(read_env_value SUPABASE_PUBLISHABLE_KEY)
sentry_dsn=$(read_env_value SENTRY_DSN)
key_source="SUPABASE_PUBLISHABLE_KEY"
if [[ -z "${publishable_key}" ]]; then
    publishable_key=$(read_env_value SUPABASE_ANON_KEY)
    key_source="SUPABASE_ANON_KEY (legacy fallback)"
fi

[[ -n "${supabase_url}" ]] || fail "SUPABASE_URL is empty"
[[ -n "${publishable_key}" ]] || fail "SUPABASE_PUBLISHABLE_KEY and SUPABASE_ANON_KEY are both empty"
[[ -n "${sentry_dsn}" ]] || fail "SENTRY_DSN is empty; TestFlight would have no client diagnostics"

case "${supabase_url}" in
    *replace-me*|*placeholder*|*example*)
        fail "SUPABASE_URL still contains a placeholder value"
        ;;
esac

ruby -r uri -e '
  value = ARGV.fetch(0)
  uri = URI.parse(value)
  abort unless uri.scheme == "https" && uri.host && !uri.host.empty? && !uri.userinfo
' "${supabase_url}" >/dev/null 2>&1 || fail "SUPABASE_URL must be an absolute HTTPS URL without user info"

case "${publishable_key}" in
    *replace-me*|*placeholder*)
        fail "${key_source} still contains a placeholder value"
        ;;
    sb_publishable_*)
        [[ ${#publishable_key} -ge 24 ]] || fail "SUPABASE_PUBLISHABLE_KEY is too short"
        ;;
    sb_secret_*)
        fail "a privileged sb_secret key must never be bundled in an iOS app"
        ;;
    eyJ*)
        jwt_role=$(ruby -r base64 -r json -e '
          token = ARGV.fetch(0)
          segment = token.split(".")[1] or abort
          segment += "=" * ((4 - segment.length % 4) % 4)
          payload = JSON.parse(Base64.urlsafe_decode64(segment))
          print payload.fetch("role")
        ' "${publishable_key}" 2>/dev/null) || fail "legacy Supabase key is not a readable JWT"
        [[ "${jwt_role}" == "anon" ]] || fail "legacy Supabase key role must be anon, never service_role"
        ;;
    *)
        fail "${key_source} is neither an sb_publishable key nor a legacy anon JWT"
        ;;
esac

case "${sentry_dsn}" in
    *replace-me*|*placeholder*|*example*)
        fail "SENTRY_DSN still contains a placeholder value"
        ;;
esac

ruby -r uri -e '
  value = ARGV.fetch(0)
  uri = URI.parse(value)
  project = uri.path.split("/").reject(&:empty?).last
  abort unless uri.scheme == "https" && uri.host && !uri.host.empty?
  abort unless uri.user && !uri.user.empty? && uri.password.nil?
  abort unless project && project.match?(/\A\d+\z/)
' "${sentry_dsn}" >/dev/null 2>&1 || fail "SENTRY_DSN must be an HTTPS public ingestion DSN with a numeric project id"

echo "[release-config] Supabase URL, ${key_source}, and Sentry DSN are valid public client configuration"

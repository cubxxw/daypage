#!/usr/bin/env bash
#
# Write the non-sensitive GeneratedSecrets.swift used by CI and local build
# gates. This deliberately does not read .env, Keychain, or process secrets.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_FILE="${1:-${REPO_ROOT}/DayPage/Config/GeneratedSecrets.swift}"

mkdir -p "$(dirname "${OUTPUT_FILE}")"
cat > "${OUTPUT_FILE}" <<'SWIFT'
// GeneratedSecrets.swift — deterministic CI placeholder.
// Real credentials are provided at runtime via Keychain. Never add them here.
enum Secrets {
    static let deepSeekApiKey: String = ""
    static let openAIWhisperApiKey: String = ""
    static let openWeatherApiKey: String = ""
    static let sentryDSN: String = ""
    static let kubotGitHubToken: String = ""
    static let doubaoASRAppID: String = ""
    static let doubaoASRAccessToken: String = ""
    static let doubaoASRSecretKey: String = ""

    static let deepSeekBaseURL: String = "https://api.deepseek.com/v1"
    static let deepSeekModel: String = "deepseek-v4-pro"
    static let supabaseURL: String = "https://placeholder.supabase.co"
    static let supabasePublishableKey: String = ""
    static let voiceASRProvider: String = "doubao"
    static let doubaoASRStreamURL: String = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"
    static let doubaoASRFileURL: String = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
}
SWIFT

echo "Wrote deterministic secrets placeholder: ${OUTPUT_FILE}"

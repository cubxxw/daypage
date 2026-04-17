#!/usr/bin/env bash
# screenshot.sh — 给当前 Simulator 截图。
# 用法：screenshot.sh <run-dir> <story-id> <slug>

set -euo pipefail

RUN_DIR="${1:?missing run-dir}"
STORY_ID="${2:?missing story-id}"
SLUG="${3:?missing slug}"

DEVICE_ID=$(jq -r '.deviceId' "$RUN_DIR/env.json")
OUT_DIR="$RUN_DIR/$STORY_ID/screenshots"
mkdir -p "$OUT_DIR"
TS=$(date +%H%M%S)
OUT="$OUT_DIR/${TS}-${SLUG}.png"

xcrun simctl io "$DEVICE_ID" screenshot "$OUT" >/dev/null
echo "$OUT"

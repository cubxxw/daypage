#!/usr/bin/env bash

# Fast, hermetic checks for contracts and request handlers owned by the backend.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

pnpm contracts:test
pnpm --filter daypage-mcp-server typecheck
pnpm --filter daypage-mcp-server test
pnpm --filter daypage-web exec vitest run \
    src/lib/auth/__tests__/safe-next.test.ts \
    src/lib/oauth/__tests__/form-origin.test.ts \
    src/lib/oauth/__tests__/consent.test.ts \
    src/lib/__tests__/api-auth.test.ts \
    src/app/api/memos/__tests__/route.test.ts \
    src/app/api/memos/bulk/__tests__/route.test.ts \
    src/app/api/mcp/__tests__/mcp.test.ts

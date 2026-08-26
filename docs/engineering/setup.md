# Local setup

## Prerequisites

- Xcode with an iOS Simulator supported by the shared `DayPage` scheme.
- Swift capable of building `DayPageKit` (`swift-tools-version: 5.9`).
- Node.js 22+ and the pnpm version pinned in the root `package.json`.
- Go 1.24 for `agentry`.
- `gh`, `jq`, and standard macOS developer tools for repository automation.

Install workspace JavaScript dependencies with the pinned package manager:

```sh
corepack enable
pnpm install --frozen-lockfile
```

Generate local Apple-side secret configuration through
`scripts/generate_secrets.sh`. Web-only values belong in ignored local environment
files. Never commit generated secrets, auth state, a personal vault, or runtime evidence.
The iOS build requires `SUPABASE_URL` plus `SUPABASE_PUBLISHABLE_KEY`; the legacy
`SUPABASE_ANON_KEY` remains a temporary fallback for existing release environments.

Run:

```sh
make doctor
```

before broad work. Doctor reports missing prerequisites and repository contract drift;
it must not install tools, mutate remote state, or release anything.

## DeepSeek Harness development host

DayPage can run the canonical `.agents` control plane through the optional, version-pinned
DeepSeek Harness adapter. Store the provider values in an owner-only dotenv file outside
the repository, or use an ignored repository `.env` containing only the three allowed
variables:

```sh
chmod 600 /path/to/daypage-dsh.env
export DAYPAGE_DSH_ENV_FILE=/path/to/daypage-dsh.env
make dsh-doctor
make dsh-web
```

The launcher reads only `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`, and
`DEEPSEEK_MODEL`; it does not source shell code or pass unrelated process secrets.
`DAYPAGE_DSH_HOME` may override the default state directory outside the checkout.
Use `make dsh-config` to inspect the effective plugin tree without starting the UI.

Harness starts with `workspace-write`, interactive approval, and both bootstrap and
session-plugin telemetry disabled. Changing the permission preset in the UI is an
explicit operator action. Agentic acceptance cases and the comparison rubric are defined in
[DSH Agentic testing](dsh-agentic-testing.md).

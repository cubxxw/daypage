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

Run:

```sh
make doctor
```

before broad work. Doctor reports missing prerequisites and repository contract drift;
it must not install tools, mutate remote state, or release anything.

# DayPage Android

The Android client is a native Jetpack Compose surface over the same identity,
memo, sync, and MCP contracts as the Apple and web clients. It deliberately does
not introduce a second backend or a second memo format.

The canonical local source is `filesDir/vault/raw/YYYY-MM-DD.md`, using the same YAML
front matter and exact memo separator as the Apple clients. Room is a rebuildable query
index plus durable outbox. Local capture writes the Vault first; remote pull mirrors its
accepted page into the Vault before advancing the server cursor.

## Local configuration

Pass public client configuration through Gradle properties or environment variables:

```text
DAYPAGE_SUPABASE_URL=https://your-project.supabase.co
DAYPAGE_SUPABASE_ANON_KEY=your-public-anon-key
```

Never place a service-role key in this project. Add `daypage://auth/callback` to the
Supabase Auth redirect allow-list for local Android OAuth testing.

## Verification

```sh
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug
```

The unit test source set reads the canonical fixtures directly from
`packages/contracts/fixtures`; Android does not keep copied protocol examples.

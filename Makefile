SHELL := /bin/bash

PYTHON ?= python3
PNPM ?= pnpm
SCHEME ?= DayPage
PROJECT ?= DayPage.xcodeproj
SIMULATOR_FALLBACK ?= iPhone 16
DERIVED_DATA ?= build/DD

.PHONY: \
	doctor check check-agent check-scripts check-kit check-web check-android check-mcp check-contracts \
	check-agentry check-localization check-tokens check-ios build-ios \
	ci-secrets simulator-destination tokens-build tokens-check \
	dsh-doctor dsh-config dsh-web

# Developer preflight: repository contracts plus the available local toolchain.
doctor:
	$(PYTHON) scripts/agent/doctor.py --root . --environment

# DeepSeek Harness is an opt-in development host. These targets never run in
# the default merge gate because the runtime probe and UI require local credentials.
dsh-doctor:
	$(PYTHON) scripts/agent/dsh.py doctor --runtime

dsh-config:
	$(PYTHON) scripts/agent/dsh.py dump-config

dsh-web:
	$(PYTHON) scripts/agent/dsh.py web

# Portable, non-Simulator merge gates. Use the scoped targets while iterating.
check: check-agent check-scripts check-kit check-web check-android check-mcp check-contracts check-agentry check-localization check-tokens

check-agent:
	$(PYTHON) scripts/agent/doctor.py --root .
	$(PYTHON) -m unittest discover -s scripts/agent -p 'test_*.py'

check-scripts:
	bash scripts/ci/run_script_tests.sh

check-kit:
	swift test --package-path DayPageKit

check-web:
	$(PNPM) web:lint
	$(PNPM) web:typecheck

check-android:
	cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug

check-mcp:
	$(PNPM) --filter daypage-mcp-server test

check-contracts:
	$(PNPM) contracts:test

check-agentry:
	cd agentry && go test ./...
	cd agentry && go vet ./...
	cd agentry && go build ./...

check-localization:
	bash scripts/check_localization_parity.sh

# Regenerate web CSS + Apple Swift + Android Compose tokens from design-tokens/tokens.json.
tokens-build:
	node --experimental-strip-types design-tokens/generators/to-css.ts
	node --experimental-strip-types design-tokens/generators/to-swift.ts
	node --experimental-strip-types design-tokens/generators/to-kotlin.ts

check-tokens: tokens-check

# CI guard: regenerate and fail if the working tree is dirty.
tokens-check: tokens-build
	git diff --exit-code -- web/src/app/globals.css DayPage/App/DSTokens.swift \
		design-tokens/generated/kotlin/app/daypage/designsystem/DayPageTokens.kt

# Direct CI helpers; ci-secrets always writes a non-sensitive placeholder.
ci-secrets:
	bash scripts/ci/write_placeholder_secrets.sh

simulator-destination:
	@xcrun simctl list devices available --json \
		| $(PYTHON) scripts/ci/select_simulator.py --format destination --fallback-name "$(SIMULATOR_FALLBACK)"

check-ios:
	@test -f DayPage/Config/GeneratedSecrets.swift || bash scripts/ci/write_placeholder_secrets.sh
	@DEST="$$(xcrun simctl list devices available --json \
		| $(PYTHON) scripts/ci/select_simulator.py --format destination --fallback-name "$(SIMULATOR_FALLBACK)")"; \
	echo "Using simulator: $$DEST"; \
	xcodebuild test -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination "$$DEST" -configuration Debug CODE_SIGNING_ALLOWED=NO

build-ios:
	@test -f DayPage/Config/GeneratedSecrets.swift || bash scripts/ci/write_placeholder_secrets.sh
	@DEST="$$(xcrun simctl list devices available --json \
		| $(PYTHON) scripts/ci/select_simulator.py --format destination --fallback-name "$(SIMULATOR_FALLBACK)")"; \
	echo "Using simulator: $$DEST"; \
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination "$$DEST" CODE_SIGNING_ALLOWED=NO \
		COMPILER_CONTENT_PROTECTION=NO -derivedDataPath "$(DERIVED_DATA)" build

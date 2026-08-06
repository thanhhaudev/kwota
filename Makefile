PROJECT     := Kwota/Kwota.xcodeproj
SCHEME      := Kwota
CONFIG      ?= Debug
BUILD_DIR   := build
APP_NAME    := Kwota.app
APP_PATH    := $(BUILD_DIR)/$(CONFIG)/$(APP_NAME)
RELEASE_APP := $(BUILD_DIR)/Release/$(APP_NAME)
INSTALL_DIR ?= /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME)

# Shared DerivedData so every worktree + subagent invocation reuses
# incremental compile cache. Override with: `make … DERIVED=/path`.
# Out-of-tree by design — an in-repo path would defeat sharing because
# each worktree has a different absolute path.
DERIVED     ?= $(HOME)/Library/Developer/Xcode/DerivedData/Kwota-shared

DESTINATION := platform=macOS
XCODEBUILD  := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED)

.PHONY: help build app run test test-all build-for-testing test-only clean clean-deep open release release-app install ensure-local-xcconfig \
        signing-setup signing-refresh signing-agent-install signing-agent-uninstall

# Local.xcconfig is gitignored — owners commit their DEVELOPMENT_TEAM there,
# public clones get an auto-created empty placeholder so xcodebuild can
# resolve baseConfigurationReference and fall back to ad-hoc signing.
ensure-local-xcconfig:
	@if [ ! -f Local.xcconfig ]; then \
	  cp Local.xcconfig.example Local.xcconfig; \
	  echo "Created empty Local.xcconfig (copy of Local.xcconfig.example)."; \
	fi

help:
	@echo "Kwota build targets:"
	@echo "  make build        Compile $(CONFIG) build (no launch)"
	@echo "  make app          Build and copy .app to $(APP_PATH)"
	@echo "  make run          Build and launch the app for manual testing"
	@echo "  make test         Run unit tests (KwotaTests; skips UI tests)"
	@echo "  make test-all     Run all tests (unit + UI)"
	@echo "  make build-for-testing  Build test bundle (call once, then test-only)"
	@echo "  make test-only SUITE=X  Run KwotaTests/X without rebuilding"
	@echo "  make release      Build Release configuration"
	@echo "  make release-app  Build Release and copy .app to build/Release/$(APP_NAME)"
	@echo "  make install      Build Release and install into $(INSTALL_DIR) (then launch)"
	@echo "  make clean        Clean build artifacts (keeps shared DerivedData)"
	@echo "  make clean-deep   Clean build artifacts AND wipe shared DerivedData"
	@echo "  make open         Open project in Xcode"
	@echo ""
	@echo "Signing:"
	@echo "  make signing-setup [TEAM=XXXXXXXXXX]  Detect/set Team ID in Local.xcconfig"
	@echo "  make signing-refresh                  Re-sign $(INSTALLED_APP) if its cert is near expiry"
	@echo "  make signing-agent-install            Run signing-refresh weekly + at login"
	@echo "  make signing-agent-uninstall          Remove that LaunchAgent"

build: ensure-local-xcconfig
	$(XCODEBUILD) build

app: build
	@mkdir -p $(BUILD_DIR)/$(CONFIG)
	@BUILT=$$($(XCODEBUILD) -showBuildSettings build 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}'); \
	  rm -rf "$(APP_PATH)"; \
	  cp -R "$$BUILT/$(APP_NAME)" "$(APP_PATH)"; \
	  echo "App copied to $(APP_PATH)"

run: app
	@echo "Launching $(APP_PATH)…"
	@open "$(APP_PATH)"

test: ensure-local-xcconfig
	$(XCODEBUILD) test -only-testing:KwotaTests \
	  -parallel-testing-enabled YES \
	  -maximum-parallel-testing-workers 4

test-all: ensure-local-xcconfig
	$(XCODEBUILD) test

# Build the test bundle without running it. Call once per task; subsequent
# `make test-only` invocations skip the build entirely.
build-for-testing: ensure-local-xcconfig
	$(XCODEBUILD) build-for-testing -only-testing:KwotaTests

# Run a single test suite WITHOUT rebuilding. Requires a prior
# `make build-for-testing` (or `make test`) since the last code change.
# Usage: make test-only SUITE=AwakeConfigTests
test-only:
	@if [ -z "$(SUITE)" ]; then \
	  echo "error: SUITE is required. Usage: make test-only SUITE=AwakeConfigTests"; \
	  exit 2; \
	fi
	$(XCODEBUILD) test-without-building -only-testing:KwotaTests/$(SUITE) \
	  -parallel-testing-enabled YES \
	  -maximum-parallel-testing-workers 4

clean:
	$(XCODEBUILD) clean
	rm -rf $(BUILD_DIR) default.profraw

clean-deep: clean
	rm -rf $(DERIVED)

open:
	open $(PROJECT)

release:
	$(MAKE) build CONFIG=Release

# release-app produces a signed Kwota.app whose Contents/MacOS also holds
# the KwotaPrivilegedHelper executable and Contents/Library/LaunchDaemons
# holds its launchd plist. Notarize the whole .app as one unit
# (`xcrun notarytool submit` on a zip of build/Release/Kwota.app, then
# `xcrun stapler staple`). The helper inherits the bundle's notarization;
# do not notarize it separately.
release-app:
	$(MAKE) app CONFIG=Release

# install drops the signed Release build into /Applications, replacing any
# previous copy, then launches it. This is the long-lived bundle that the
# signing auto-refresh LaunchAgent guards (scripts/install-signing-refresh.sh).
# Override the destination with: `make install INSTALL_DIR=/path`.
install: release-app
	@osascript -e 'tell application "Kwota" to quit' 2>/dev/null || true
	@rm -rf "$(INSTALLED_APP)"
	@cp -R "$(RELEASE_APP)" "$(INSTALLED_APP)"
	@echo "Installed $(INSTALLED_APP)"
	@open "$(INSTALLED_APP)"

# --- Signing -----------------------------------------------------------------
#
# Thin wrappers over scripts/. The scripts stay the source of truth (they are
# portable, resolve the repo from their own location, and are what the
# LaunchAgent invokes); these targets exist so the signing lifecycle is
# discoverable from `make help` alongside everything else, instead of only
# from the README.

# Detects your Apple Team ID from the login keychain and writes it to
# Local.xcconfig (gitignored). Pass TEAM= to skip detection:
#   make signing-setup TEAM=WDCHM35284
signing-setup:
	@bash scripts/setup-signing.sh $(TEAM)

# A development signature carries no secure timestamp, so once its leaf
# certificate expires macOS stops launching the app and launchd stops loading
# the privileged helper. This re-signs the long-lived $(INSTALL_DIR) copy when
# the cert is within the script's threshold — and reports "cert good" and does
# nothing when it is not, so it is safe to run any time.
signing-refresh:
	@bash scripts/refresh-signing.sh

signing-agent-install:
	@bash scripts/install-signing-refresh.sh install

signing-agent-uninstall:
	@bash scripts/install-signing-refresh.sh uninstall

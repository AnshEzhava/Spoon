CONFIG  ?= debug
ARCHS   ?=
APP     := build/Spoon.app
ICON    := build/AppIcon.icns
SWIFT_FLAGS := -c $(CONFIG) $(foreach a,$(ARCHS),--arch $(a))
BIN      = $(shell swift build $(SWIFT_FLAGS) --show-bin-path)

# Signing. SIGN=adhoc | dev (Apple Development: runs on this Mac) | dist (Developer ID: runs anywhere, notarizable).
# Defaults to dev when an Apple Development certificate is installed, so Keychain "Always Allow" survives rebuilds.
# ponytail: dev takes the first Apple Development identity; pass SIGN_ID=<sha1> if this Mac has several accounts.
TEAM_ID        ?= 9892P9EHK7
NOTARY_PROFILE ?= spoon-notary
DEV_CERT       := $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / {print $$2; exit}')
DIST_CERT      := $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application: .*\($(TEAM_ID)\)"/ {print $$2; exit}')
SIGN           ?= $(if $(DEV_CERT),dev,adhoc)
SIGN_ID        ?= $(if $(filter dist,$(SIGN)),$(DIST_CERT),$(if $(filter dev,$(SIGN)),$(DEV_CERT),-))
# Notarization needs a secure timestamp; local builds skip the round trip to Apple.
CODESIGN        = codesign --force --options runtime --sign "$(SIGN_ID)" $(if $(filter dist,$(SIGN)),--timestamp,--timestamp=none)

.DEFAULT_GOAL := help
.PHONY: help build test app signed dev run spoon signing notary-setup release install-cli clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

build: ## Compile all targets (CONFIG=debug|release)
	swift build $(SWIFT_FLAGS)

test: ## Run SpoonKit unit + integration tests
	swift test

# All iconset sizes from the 1254 px source logo; rebuilt only when spoon.png changes.
$(ICON): spoon.png
	@rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s $< --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) $< --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	@iconutil -c icns build/AppIcon.iconset -o $@

app: build $(ICON) ## Assemble and sign build/Spoon.app (SIGN=adhoc|dev|dist)
	@test -n "$(SIGN_ID)" || { echo "No Developer ID Application certificate for team $(TEAM_ID). See: make signing"; exit 1; }
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	@cp $(BIN)/SpoonApp $(APP)/Contents/MacOS/Spoon
	@cp $(BIN)/spoon $(BIN)/SpoonAskpass $(APP)/Contents/Helpers/
	@$(CODESIGN) $(APP)/Contents/Helpers/spoon $(APP)/Contents/Helpers/SpoonAskpass
	@$(CODESIGN) $(APP)
	@echo "Built $(APP) ($(CONFIG), signed: $(SIGN))"

signed: ## Build the app signed with your Apple Development certificate (this Mac only)
	@$(MAKE) app SIGN=dev

dev: app ## Build debug app and run it in the foreground with logs
	SPOON_DEV=1 $(APP)/Contents/MacOS/Spoon

run: app ## Build and launch the app detached
	open $(APP)

spoon: build ## Run the CLI, e.g. make spoon ARGS="-C ~/Code/x status"
	@$(BIN)/spoon $(ARGS)

signing: ## Show signing certificates and notarization setup
	@echo "Team:              $(TEAM_ID)"
	@echo "Apple Development: $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development: / {print $$2; exit}'),missing — Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates)"
	@echo "Developer ID:      $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Developer ID Application: .*\($(TEAM_ID)\)"/ {print $$2; exit}'),missing — Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application)"
	@printf "Notary profile:    $(NOTARY_PROFILE) "; xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 \
		&& echo "(ok)" || echo "(missing — make notary-setup APPLE_ID=you@example.com)"

notary-setup: ## One-time: save notarization credentials to the Keychain (APPLE_ID=…)
	@test -n "$(APPLE_ID)" || { echo "usage: make notary-setup APPLE_ID=<the Apple ID of your developer account>"; exit 1; }
	@echo "Paste an app-specific password from https://account.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords"
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --apple-id "$(APPLE_ID)" --team-id "$(TEAM_ID)"

release: ## Universal build, Developer ID signed, notarized and stapled → build/Spoon.zip
	@test -n "$(DIST_CERT)" || { echo "No Developer ID Application certificate for team $(TEAM_ID). See: make signing"; exit 1; }
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 || { echo "No notary profile '$(NOTARY_PROFILE)'. Run: make notary-setup APPLE_ID=…"; exit 1; }
	$(MAKE) app CONFIG=release ARCHS="arm64 x86_64" SIGN=dist
	codesign --verify --strict --verbose=2 $(APP)
	ditto -c -k --keepParent $(APP) build/Spoon.zip
	xcrun notarytool submit build/Spoon.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	ditto -c -k --keepParent $(APP) build/Spoon.zip
	spctl --assess --type execute --verbose=2 $(APP)
	@echo "Ready to share: build/Spoon.zip"

install-cli: app ## Symlink the bundled spoon CLI into /usr/local/bin
	ln -sf "$(abspath $(APP))/Contents/Helpers/spoon" /usr/local/bin/spoon

clean: ## Remove build products
	rm -rf .build build

APP_NAME   := Parfait
BUNDLE_ID  := io.github.conrad-vanl.Parfait
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
BINARY     := .build/release/$(APP_NAME)
# Ad-hoc by default. For a stable TCC identity across rebuilds we pin an explicit
# designated requirement. Set SIGN_ID to your "Apple Development: ..." identity
# for the best experience (permissions survive rebuilds without re-prompting).
# The release pipeline (.github/workflows/release.yml) overrides SIGN_ID with the
# "Developer ID Application: ..." identity so the notarized build reuses this logic.
SIGN_ID    ?= -

# Hardened Runtime (-o runtime + entitlements) is required for notarization and is the
# default: verified end-to-end on 2026-07-09 — it launches cleanly and a real recording
# captures BOTH the mic AND the Core Audio system-audio process tap, then transcribes,
# diarizes (2 speakers) and summarizes, all under -o runtime with only com.apple.security.*
# entitlements (no provisioning profile needed). Set HARDENED=0 for a plain ad-hoc
# signature (no runtime/entitlements) if ever needed for debugging.
HARDENED   ?= 1
ifeq ($(HARDENED),1)
RUNTIME_ARGS := -o runtime --entitlements packaging/Parfait.entitlements
else
RUNTIME_ARGS :=
endif

.PHONY: build test app run install relaunch icon og clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp packaging/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@# SwiftPM resource bundle (menu bar icon) must ride along or Bundle.module lookups fail
	@if [ -d ".build/release/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R ".build/release/$(APP_NAME)_$(APP_NAME).bundle" "$(APP)/Contents/Resources/"; \
	fi
	@# RUNTIME_ARGS is empty for local dev (HARDENED=0) and adds -o runtime + entitlements
	@# for the notarizable release build (HARDENED=1). All entitlements are
	@# com.apple.security.* keys, honored ad-hoc with no provisioning profile.
	codesign --force --sign "$(SIGN_ID)" $(RUNTIME_ARGS) \
		-r='designated => identifier "$(BUNDLE_ID)"' "$(APP)"
	@echo "Built $(APP) (HARDENED=$(HARDENED))"

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

# Kill running instance, wipe old bundles, rebuild, install to /Applications, and launch.
relaunch:
	-pkill -x $(APP_NAME)
	rm -rf "/Applications/$(APP_NAME).app" "$(APP)"
	$(MAKE) install
	open "/Applications/$(APP_NAME).app"

# Regenerate every icon artifact the app actually ships from the drawing code:
# the .icns bundled by `make app` and the @1x/@2x menu-bar template glyphs
# loaded via Bundle.module. Keeps the README hero (AppIcon-1024.png) fresh too.
icon:
	swift scripts/MakeIcon.swift Resources
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Sources/Parfait/Resources/
	rm -rf Resources/AppIcon.iconset Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/MenuBarIcon-preview.png

# Regenerate the parfait.to Open Graph preview image (site/og-image.png)
# from the drawing code, reusing the shipped 1024px app icon.
og:
	mkdir -p site
	swift scripts/MakeOGImage.swift Resources/AppIcon-1024.png site

clean:
	rm -rf .build "$(DIST)"

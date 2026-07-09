APP_NAME   := Parfait
BUNDLE_ID  := io.github.conrad-vanl.Parfait
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
BINARY     := .build/release/$(APP_NAME)
# Ad-hoc by default. For a stable TCC identity across rebuilds we pin an explicit
# designated requirement. Set SIGN_ID to your "Apple Development: ..." identity
# for the best experience (permissions survive rebuilds without re-prompting).
SIGN_ID    ?= -

.PHONY: build test app run install icon og clean

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
	codesign --force --sign "$(SIGN_ID)" -r='designated => identifier "$(BUNDLE_ID)"' "$(APP)"
	@echo "Built $(APP)"

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

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

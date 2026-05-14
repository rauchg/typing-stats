# Local dev build: no certs, no notarization, no auto-update.
# DEV_BUILD excludes Sparkle from the SPM dependency graph entirely
# and compiles out all update-related code via #if guards.

APP = TypingStats
BUILD = .build/release/$(APP)
BUNDLE = Typing Stats.app
INSTALL_DIR = /Applications

dev:
	DEV_BUILD=1 swift build -c release -Xswiftc -DDEV_BUILD

dev-bundle: dev
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS"
	mkdir -p "$(BUNDLE)/Contents/Resources"
	cp $(BUILD) "$(BUNDLE)/Contents/MacOS/"
	cp Info.plist "$(BUNDLE)/Contents/"
	cp AppIcon.icns "$(BUNDLE)/Contents/Resources/"
	codesign --force --deep --sign - "$(BUNDLE)"

dev-install: dev-bundle
	cp -r "$(BUNDLE)" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(BUNDLE)"

dev-uninstall:
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)"

clean:
	swift package clean
	rm -rf "$(BUNDLE)"

.PHONY: dev dev-bundle dev-install dev-uninstall clean

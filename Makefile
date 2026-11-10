# macdisplay — build the CLI and the menu bar .app with plain swiftc (no Xcode, no SwiftPM).
#   make cli      → ./macdisplay            (status / off / on / toggle)
#   make app      → ./MacDisplay.app        (menu bar app; carries the CLI in Contents/MacOS too)
#   make all      → both
#   make install  → copy MacDisplay.app to $(APPDIR), /Applications by default
#   make clean    → remove build artifacts

# Without -target the binaries would require the macOS version they were built on.
SWIFTC  := swiftc -O -target arm64-apple-macos13.0
VERSION := $(shell sed -n 's/^let version = "\(.*\)"$$/\1/p' core.swift)
APP     := MacDisplay.app
APPDIR  ?= /Applications
# zsh passes APPDIR=~/Applications through unexpanded, and the quotes in `install` keep it literal.
override APPDIR := $(patsubst ~/%,$(HOME)/%,$(APPDIR))

.PHONY: all cli app install clean

all: cli app

cli:
	$(SWIFTC) -o macdisplay core.swift main.swift

build/AppIcon.icns: assets/AppIcon.png
	mkdir -p build/AppIcon.iconset
	set -e; for size in 16 32 128 256 512; do \
		sips -z $$size $$size $< --out build/AppIcon.iconset/icon_$${size}x$${size}.png >/dev/null; \
		double=$$((size * 2)); \
		sips -z $$double $$double $< --out build/AppIcon.iconset/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o $@

# The bundle is rebuilt from scratch and replaced whole: writing over the executable of a
# running app in place can crash it, while removing the old bundle leaves the running copy alone.
app: cli build/AppIcon.icns
	$(SWIFTC) -o build/MacDisplayBar core.swift menubar.swift
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp build/MacDisplayBar macdisplay $(APP)/Contents/MacOS/
	cp build/AppIcon.icns $(APP)/Contents/Resources/
	cp Info.plist $(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string $(VERSION) $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string $(VERSION) $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

install: app
	mkdir -p "$(APPDIR)"
	rm -rf "$(APPDIR)/$(APP)"
	cp -R $(APP) "$(APPDIR)/$(APP)"

clean:
	rm -rf macdisplay build $(APP)

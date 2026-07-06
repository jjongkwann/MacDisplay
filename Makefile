# macdisplay — build the CLI and the menu bar .app with plain swiftc (no Xcode, no SwiftPM).
#   make cli    → ./macdisplay              (status / off / on / toggle)
#   make app    → ./MacDisplay.app          (double-clickable menu bar app)
#   make all    → both
#   make clean  → remove build artifacts

.PHONY: all cli app clean

all: cli app

cli:
	swiftc -O -o macdisplay core.swift main.swift

app:
	mkdir -p build MacDisplay.app/Contents/MacOS
	swiftc -O -o build/MacDisplayBar core.swift menubar.swift
	cp build/MacDisplayBar MacDisplay.app/Contents/MacOS/MacDisplayBar
	cp Info.plist MacDisplay.app/Contents/Info.plist

clean:
	rm -rf macdisplay build MacDisplay.app

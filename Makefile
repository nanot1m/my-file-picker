APP := build/FilePicker.app
BIN := .build/release/FilePicker
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)
DIST := build/dist/FilePicker-$(VERSION).zip
# A stable identity keeps Accessibility grants across rebuilds; "-" (ad-hoc) changes every build.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Local Dev" && echo "Local Dev" || echo -)

.PHONY: build bundle run stop test bench asan tsan dist icon clean

build:
	swift build -c release

bundle: build
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/FilePicker
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	sed 's/__VERSION__/$(VERSION)/' Resources/Info.plist > $(APP)/Contents/Info.plist
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(APP)

dist: bundle
	mkdir -p build/dist
	rm -f $(DIST)
	ditto -c -k --keepParent $(APP) $(DIST)
	cd build/dist && shasum -a 256 $(notdir $(DIST)) | tee $(notdir $(DIST)).sha256

run: bundle stop
	open $(APP)

stop:
	-pkill -x FilePicker

test:
	swift test

bench: build
	.build/release/fsbench $(HOME) 10 --baseline

asan:
	swift build -Xswiftc -sanitize=address -Xcc -fsanitize=address
	swift test -Xswiftc -sanitize=address -Xcc -fsanitize=address

tsan:
	swift build -Xswiftc -sanitize=thread -Xcc -fsanitize=thread

icon:
	swiftc -O -o build/render-icon scripts/render-icon.swift
	build/render-icon build/icon-1024.png
	rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  sips -z $$((s*2)) $$((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
	sips -z 512 512 build/icon-1024.png --out docs/icon.png >/dev/null

clean:
	rm -rf .build build

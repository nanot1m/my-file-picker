APP := build/FilePicker.app
BIN := .build/release/FilePicker
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)
DIST := build/dist/FilePicker-$(VERSION).zip
# A stable identity keeps Accessibility grants across rebuilds; "-" (ad-hoc) changes every build.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "FilePicker Dev" && echo "FilePicker Dev" || echo -)

.PHONY: build bundle run stop test bench asan tsan dist clean

build:
	swift build -c release

bundle: build
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/FilePicker
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

clean:
	rm -rf .build build

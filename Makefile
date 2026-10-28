APP := build/FilePicker.app
BIN := .build/release/FilePicker

.PHONY: build bundle run stop test bench asan tsan clean

build:
	swift build -c release

bundle: build
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/FilePicker
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

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

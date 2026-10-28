# File Picker

A keyboard-first, Spotlight-style file navigator for macOS. Press ⌥ Space, type a few letters, hit Enter.

Native AppKit UI on top of a small C filesystem engine. No Electron, no web views, no dependencies.

- Fuzzy search inside the current folder as you type
- Create a folder or file by typing a name that doesn't exist yet
- Open with any application, picked with the same fuzzy search
- Copy absolute or `~/`-relative paths
- Menu-bar agent, no Dock icon, one reusable floating panel
- Directory enumeration via `getattrlistbulk()`, off the main thread, ~40 bytes per entry

## Install

Requires macOS 13+ on Apple Silicon.

**Download.** Grab `FilePicker-<version>.zip` from the [latest release](https://github.com/nanot1m/my-file-picker/releases/latest), unzip, and move `FilePicker.app` to `/Applications`. The app is ad-hoc signed, not notarized, so the first launch needs the quarantine flag cleared:

```
xattr -dr com.apple.quarantine /Applications/FilePicker.app
open /Applications/FilePicker.app
```

**Build from source.** Needs the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is not needed.

```
git clone https://github.com/nanot1m/my-file-picker.git
cd my-file-picker
make run
```

`make run` builds in release mode, assembles `build/FilePicker.app`, and launches it. A folder icon appears in the menu bar. Copy the bundle to `/Applications` and add it to Login Items if you want it to start at login.

## Keys

| Key | Action |
|---|---|
| ⌥ Space | Show / hide the panel |
| type | Fuzzy-filter the current folder |
| ↑ ↓ | Move selection (Page Up / Page Down jump) |
| → or Enter | Enter the selected folder |
| Enter | Open the selected file with its default app |
| ← | Go to the parent folder (when the search field is empty) |
| ⌘C | Copy the absolute path |
| ⌘⇧C | Copy the path relative to home, e.g. `~/dev/project` |
| ⌘⇧O | Pick an application in the same panel; Enter opens with it, Esc goes back |
| Esc | Clear the search, then hide |

When the typed name doesn't match anything exactly, two extra rows appear at the end of the list: **Create folder** and **Create file**. Enter on either creates it in the current folder and selects it.

## Permissions

- No Full Disk Access and no Accessibility permission. The global hotkey uses Carbon `RegisterEventHotKey`.
- macOS asks for per-folder consent the first time you enter Desktop, Documents, Downloads, iCloud Drive, or removable volumes. If you decline, the panel shows "Permission denied" and stays where it was.

## Architecture

```
Sources/FSEngine        C engine: enumeration, string arena, sorting, fuzzy matching
Sources/FilePicker      AppKit app: hotkey, panel, table, keyboard handling
Sources/fsbench         standalone enumeration benchmark
Tests/FSEngineTests     engine tests (Swift Testing)
```

**Engine.** `fse_dir_read()` opens the directory once and drains it with `getattrlistbulk()`, so names, types, sizes and flags arrive without a `stat()` per entry. Entries are a flat array of 24-byte records whose names live in one growable arena. Directories sort before files using a case-insensitive, digit-aware comparison. Volumes that don't support bulk attributes fall back to `readdir` + `fstatat`. `fse_filter()` scores every entry against the query (prefix, word-boundary, camel-case and consecutive-run bonuses) and returns matches best-first.

**App.** A single non-activating `NSPanel` holds a search field, a view-based `NSTableView` with reused cells, and a hints bar. All filesystem work runs on a serial background queue. Every request carries a generation number and results that arrive after a newer request are dropped, so fast navigation never shows a stale list. The search field keeps focus permanently; arrow keys, Enter and Esc are intercepted from the field editor.

## Performance

Measured on an M-series laptop, release build, warm cache:

| | |
|---|---|
| Home directory enumerate + sort | ~0.1 ms |
| 100,000-entry directory enumerate + sort | ~150 ms, 42 bytes/entry |
| vs. `readdir` + `fstatat` | 1.6–2.0× faster |
| Fuzzy filter of ~30 entries | ~1 ms including table reload |
| Panel show to ordered front | ~10 ms |

Reproduce with:

```
make bench                              # home directory vs. readdir baseline
.build/release/fsbench /some/dir 10 --baseline
FP_PERF=1 build/FilePicker.app/Contents/MacOS/FilePicker   # per-action latencies on stderr
```

Latencies are also emitted as `os_signpost` events under the `com.hazam.filepicker` subsystem for Instruments.

## Development

```
make test     # engine tests
make asan     # AddressSanitizer build
make bundle   # build the .app without launching
make dist     # zip + sha256 under build/dist, versioned from the latest git tag
```

CI runs build, tests, bundle, and a benchmark smoke test on every push and pull request. Pushing a `v*` tag runs the tests, builds the zip, and publishes a GitHub release with generated notes:

```
git tag v0.2.0 && git push origin v0.2.0
```

Roadmap: directory cache with FSEvents invalidation, async per-file icons, incremental delivery for very large folders.

## License

MIT

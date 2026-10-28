# File Picker

Keyboard-first floating file navigator for macOS (Apple Silicon). AppKit UI, C filesystem engine.

## Build & run

Requires Command Line Tools with Swift 5.9+ (no Xcode needed).

```
make run      # release build, assemble build/FilePicker.app, launch (menu-bar agent, no Dock icon)
make test     # engine unit tests (Swift Testing)
make bench    # fsbench against $HOME vs readdir+fstatat baseline
make asan     # AddressSanitizer build
FP_PERF=1 build/FilePicker.app/Contents/MacOS/FilePicker   # log latency measurements to stderr
```

`fsbench <dir> [iterations] [--hidden] [--baseline]` runs the enumerator standalone.

## Keys

| Key | Action |
|---|---|
| ⌥ Space | Toggle launcher |
| typing | Fuzzy-filter the current directory; a name that doesn't exist offers "Create folder" / "Create file" |
| ↑ / ↓ | Move selection |
| → / Enter | Enter directory; Enter opens files with the default app or creates the typed name |
| ← | Parent directory (when the search field is empty) |
| ⌘C | Copy absolute path |
| ⌘⇧O | Open with chosen application |
| Esc | Clear search, then hide |

## Layout

- `Sources/FSEngine` — C engine: `getattrlistbulk()` enumeration, string arena, dirs-first natural sort, readdir fallback.
- `Sources/FilePicker` — AppKit agent: Carbon hotkey, non-activating `NSPanel`, view-based `NSTableView`, background loader with stale-result discard.
- `Sources/fsbench` — standalone enumeration benchmark.
- `Tests/FSEngineTests` — engine tests.

## Permissions

- No Full Disk Access or Accessibility permission required. The global hotkey uses Carbon `RegisterEventHotKey`.
- macOS prompts for per-folder access (Desktop, Documents, Downloads, removable volumes) the first time you enter them. Denied folders show "Permission denied" and the current directory stays put.

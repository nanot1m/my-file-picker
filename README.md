# File Picker

A keyboard-first, Spotlight-style file navigator for macOS. Press ⌥ Space, type a few letters, hit Enter.

Native AppKit UI on top of a small C filesystem engine. No Electron, no web views, no dependencies.

- Fuzzy search inside the current folder as you type
- Create a folder or file by typing a name that doesn't exist yet
- Open with any application, picked with the same fuzzy search
- Copy absolute or `~/`-relative paths
- Menu-bar agent, no Dock icon, one reusable floating panel that always opens on a home start page with your favorites and recent folders
- Directory enumeration via `getattrlistbulk()`, off the main thread, ~40 bytes per entry

## Install

Requires macOS 13+ on Apple Silicon.

**Download.** Grab `FilePicker-<version>.zip` from the [latest release](https://github.com/nanot1m/my-file-picker/releases/latest), unzip, and move `FilePicker.app` to `/Applications`. Releases are Developer ID signed and notarized, so the app opens without warnings. It lives in the menu bar; add it to Login Items if you want it at startup. Updates install themselves (configurable in Settings).

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
| ⌥ Space | Show / hide the panel (change it in Settings, ⌘,) |
| type | Fuzzy-filter the current folder. A `/` enters the highlighted folder: type `de`, check the highlight (move it with ↑↓ if needed), press `/`, repeat for the next level. `/` alone goes to the root, `~/` home, `../` up |
| ↑ ↓ | Move selection (Page Up / Page Down jump) |
| → or Enter | Enter the selected folder |
| Enter | Open the selected file with its default app |
| ⌘ Enter | Actions for the selected item, fuzzy-searchable in the same panel |
| start page | The panel always opens in your home folder, with favorites (★) and recent folders (🕒) listed above its contents. Typing filters them too. Add or remove favorites and clear recents from the ⌘ Enter actions list, or in Settings |
| ⌘S / Tab | Selection mode: Enter marks the current row, Tab marks and moves on, ⇧Tab moves back, ⌘A marks all, Esc leaves. ⌘ Enter then runs an action on every marked item (Open, Open With, Reveal, Duplicate, Copy, Paste into app, Copy paths, Trash) |
| ⌘P | Toggle a preview column: Quick Look for files, a contents listing for folders (persists) |
| ← | Go to the parent folder (when the search field is empty) |
| ⌘↑ | Go to the parent folder, even while a search is typed |
| ⌘C | Copy the absolute path |
| ⌘⇧C | Copy the path relative to home, e.g. `~/dev/project` |
| ⌘⇧O | Open with an application, picked with fuzzy search |
| ⌘R | Rename inline; the name is pre-selected without its extension |
| ⌘D | Duplicate as "Name copy" |
| ⌘V | Paste files from the clipboard into the current folder |
| ⌘⇧V | Paste the selected file into the app you came from (e.g. a Telegram or Slack message box) |
| ⌘, | Settings: record a different trigger shortcut |
| Esc | Clear the search, then go back, then hide |

Leaving the actions or open-with list restores the previous search and selection. The actions list offers Open, Open With, Reveal in Finder, Rename, Duplicate, Copy, Paste into the previous app, Paste Here, Copy Path, Copy ~ Path, and Move to Trash. Copy and Paste use the system file pasteboard, so they interoperate with Finder. Move to Trash is available only from the actions list, never from a bare shortcut, and nothing is ever deleted permanently.

When the typed name doesn't match anything exactly, two extra rows appear at the end of the list: **Create folder** and **Create file**. Enter on either creates it in the current folder and selects it.

## Updates

The app checks GitHub Releases every six hours and on "Check for Updates…" in the menu-bar menu or Settings. With "Install updates automatically" on (the default), a newer release is downloaded, its code signature verified (and its Team ID matched to the installed app's when the installed app has one), swapped into place, and the app relaunches. Turn it off in Settings to be asked first. Builds running from the repo's `build/` folder never self-replace.

## Permissions

- No Full Disk Access. The global hotkey uses Carbon `RegisterEventHotKey`, which needs no Accessibility permission.
- "Paste into app" (⌘⇧V) sends a ⌘V keystroke to the previous app, which does require Accessibility. Grant it from Settings (⌘,). Until granted, the file is still placed on the clipboard so a manual ⌘V works.

### Keeping the Accessibility grant across rebuilds

macOS ties the grant to the app's code signature. An ad-hoc signature (the default) changes on every build, so the entry in System Settings goes stale and the app reports "Not granted" even though its toggle is on. To avoid that when building from source, create a local signing identity once:

1. Open Keychain Access, then Keychain Access menu, Certificate Assistant, Create a Certificate.
2. Name: `Local Dev`. Identity Type: Self Signed Root. Certificate Type: Code Signing. Create.
3. Run `tccutil reset Accessibility com.hazam.filepicker` to drop the stale entry, then `make run` and grant again.

`make bundle` signs with `Local Dev` automatically when it exists, or pass `CODESIGN_IDENTITY="Apple Development: …"` to use a developer certificate.
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

## Signed releases

See [release setup and required GitHub secrets](docs/RELEASING.md) for automated Developer ID signing, Apple notarization, stapling, and GitHub Releases.

# Changelog

All notable changes to File Picker are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

The Release workflow publishes the section matching the pushed tag as the GitHub release notes, so every release needs its section here before tagging.

## [Unreleased]

## [0.7.0] - 2026-10-29

### Added
- Per-folder sorting, remembered between visits: by name (default) or by date added, newest first. Choose with ⌘⇧S or "Sort This Folder…" in the actions list; the path label shows a non-default sort.

## [0.6.0] - 2026-10-28

### Added
- Start page: the panel always opens in your home folder with favorites (★) and recent folders (🕒) listed above its contents. "Add to Favorites" / "Remove from Favorites" in the actions list; "Remove from Recents" and "Clear Recents" on recent rows.
- Path-pattern search: a `/` in the query matches each segment against nested folders (`de/src/Lau`), with results shown alongside their relative paths. Leading `/` or `~/` searches from the root or home; `../` steps up.
- Backspace on an empty search box goes to the parent folder (ignores key auto-repeat).
- Settings: show or hide the start-page shortcuts, set how many recent folders to show, and clear recents.

### Changed
- The last visited folder is no longer remembered between panel openings.

### Fixed
- Status no longer shows a stale "0 of N" after Esc clears a search inside a picker.

## [0.5.0] - 2026-10-28

### Added
- Selection mode: ⌘S or Tab marks several items (checkboxes before names, Enter toggles in place, ⇧Tab moves back, ⌘A marks all); ⌘Enter runs a batch action on all marked items (Open, Open With, Reveal, Duplicate, Copy, Paste into app, Copy Paths, Move to Trash).
- Folder preview: with the preview column open, selecting a folder lists its contents with an item count.
- ⌘↑ goes to the parent folder even while a search is typed.
- Hints bar rendered as keycap chips; items that don't fit are dropped whole instead of truncated.

### Changed
- Move to Trash is only available from the actions list; the ⌘⌫ shortcut was removed to prevent accidental deletions.
- The shortcut recorder in Settings arms only on click (or accessibility press), so opening Settings can't rebind the hotkey by accident.
- Release script logs each step with timestamps and polls notarization status instead of blocking silently.

### Fixed
- Preview layout ran before all list views existed, letting the selection highlight and status overflow into the preview column at startup.

## [0.4.0] - 2026-10-28

### Added
- Quick Look preview column toggled with ⌘P; the panel keeps its width and the list narrows.
- App icon.
- Landing page at nanot1m.github.io/my-file-picker, deployed from `docs/` by GitHub Pages.

### Changed
- Releases are signed with a Developer ID and notarized; the quarantine step is gone from the install instructions.
- Local builds sign with a self-signed `Local Dev` identity when present, so macOS keeps folder and Accessibility grants across rebuilds.

## [0.3.1] - 2026-10-28

### Added
- Check for Updates in the menu-bar menu and Settings, with automatic self-update from GitHub Releases (signature-verified, swap in place, relaunch). Development builds under `build/` never self-replace.
- Settings: Accessibility status with a Grant button.

### Fixed
- Release script imported the certificate without its private key (`security import -t cert`) and crashed on empty notarytool output.

## [0.2.1] - 2026-10-28

### Added
- Settings window (⌘,) with a recorder to rebind the trigger shortcut; Settings item in the menu-bar menu.
- Returning from the actions or open-with list restores the previous search, selection and scroll position.

### Fixed
- Fuzzy scorer dropped legitimate matches deep in a name by returning a negative score.
- Command shortcuts matched on typed characters and failed under non-Latin keyboard layouts; they now match physical keys.

## [0.2.0] - 2026-10-28

### Added
- Actions list on ⌘Enter: Open, Open With, Reveal in Finder, Rename (inline), Duplicate, Copy, Paste Here, Copy Path, Copy ~ Path, Move to Trash.
- Paste the selected file into the previous app with ⌘⇧V (requires Accessibility).
- Copy the home-relative path with ⌘⇧C.
- Open With picker inside the panel with fuzzy search.
- CI on every push and a tag-driven release workflow with `make dist`.

## [0.1.0] - 2026-10-28

### Added
- Native AppKit launcher toggled with ⌥Space: floating panel, keyboard navigation, open, copy path.
- C filesystem engine using `getattrlistbulk()` with a string arena, dirs-first natural sort, and `readdir` fallback.
- Fuzzy search field with "Create folder" / "Create file" rows for unmatched names.
- Hints bar, transparent rounded corners, standalone `fsbench` benchmark, engine tests.

[Unreleased]: https://github.com/nanot1m/my-file-picker/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/nanot1m/my-file-picker/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/nanot1m/my-file-picker/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/nanot1m/my-file-picker/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/nanot1m/my-file-picker/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/nanot1m/my-file-picker/compare/v0.2.1...v0.3.1
[0.2.1]: https://github.com/nanot1m/my-file-picker/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nanot1m/my-file-picker/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nanot1m/my-file-picker/releases/tag/v0.1.0

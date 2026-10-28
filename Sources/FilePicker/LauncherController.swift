import AppKit
import FSEngine
import Quartz

final class LauncherController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let lastDirectoryKey = "lastDirectory"
    private static let listSize = NSSize(width: 680, height: 460)
    private static let previewWidth: CGFloat = 300
    private static let previewKey = "previewEnabled"
    private static let browseHints: [Hint] = [
        Hint(key: "↵", label: "open"), Hint(key: "⌘↵", label: "actions"), Hint(key: "⌘↑", label: "up"), Hint(key: "⌘P", label: "preview"),
        Hint(key: "⌘C", label: "copy path"), Hint(key: "⌘⇧V", label: "paste into app"),
        Hint(key: "⌘R", label: "rename"), Hint(key: "esc", label: "close"),
    ]
    private static let selectionHints: [Hint] = [
        Hint(key: "⇥", label: "mark"), Hint(key: "⌘A", label: "mark all"), Hint(key: "⌘↵", label: "actions for marked"),
        Hint(key: "esc", label: "done"),
    ]
    private var browseHints: [Hint] { selectionMode ? Self.selectionHints : Self.browseHints }
    private static let browsePlaceholder = "Search or type a new name"

    private enum Row {
        case entry(Int)
        case createFolder
        case createFile
    }

    private struct Picker {
        let title: String
        let placeholder: String
        let hints: [Hint]
        let listing: DirectoryListing
        let icon: (Int) -> NSImage
        let select: (Int) -> Void
    }

    private struct Action {
        let title: String
        let symbol: String
        let run: () -> Void
    }

    private struct BrowseState {
        let listing: DirectoryListing
        let row: Int
        let query: String
        let matches: [UInt32]?
        let showCreateRows: Bool
        let scrollOrigin: NSPoint
    }

    private enum Mode {
        case browse
        case picker(Picker, saved: BrowseState)
        case rename(target: String, saved: BrowseState)
    }

    var openSettings: (() -> Void)?
    private var panel: LauncherPanel!
    private let pathLabel = NSTextField(labelWithString: "")
    private let searchField = NSTextField()
    private let hintsBar = HintsBar(frame: .zero)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let previewSeparator = NSBox()
    private var horizontalSeparators: [NSBox] = []
    private let previewView = QLPreviewView(frame: .zero, style: .normal)!
    private var previewEnabled = UserDefaults.standard.bool(forKey: previewKey)
    private var previewUpdate: DispatchWorkItem?

    private let loader = DirectoryLoader()
    private let workQueue = DispatchQueue(label: "com.hazam.filepicker.work", qos: .userInteractive)
    private var listing: DirectoryListing?
    private var mode: Mode = .browse
    private var currentPath: String
    private var previousApp: NSRunningApplication?
    private var includeHidden = false

    private var query = ""
    private var selectionMode = false
    private var marked = Set<Int>()
    private var filterGeneration: UInt64 = 0
    private var matches: [UInt32]?
    private var showCreateRows = false
    private var stats = ""

    private let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private let fileIcon = NSWorkspace.shared.icon(for: .data)
    private let linkIcon = NSWorkspace.shared.icon(for: .symbolicLink)
    private var iconCache: [String: NSImage] = [:]

    override init() {
        currentPath = UserDefaults.standard.string(forKey: Self.lastDirectoryKey) ?? NSHomeDirectory()
        super.init()
    }

    func prepare() {
        buildPanel()
        navigate(to: currentPath)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func hideIfVisible() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func show() {
        let t0 = Perf.now()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        let size = Self.listSize
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.midY - size.height / 2 + frame.height * 0.12))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        NSApp.activate(ignoringOtherApps: true)
        if tableView.selectedRow < 0, rowCount > 0 { selectRow(0) }
        Perf.report("launcher.show", since: t0)
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - UI construction

    private func buildPanel() {
        panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: Self.listSize))
        panel.delegate = self
        panel.onCommand = { [weak self] selector in self?.handleCommand(selector) ?? false }

        let w = Self.listSize.width, h = Self.listSize.height
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.listSize))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Masks.roundedRect(radius: 12)
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        pathLabel.frame = NSRect(x: 16, y: h - 26, width: w - 32, height: 16)
        pathLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.autoresizingMask = [.minYMargin]
        effect.addSubview(pathLabel)

        searchField.frame = NSRect(x: 14, y: h - 62, width: w - 28, height: 30)
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.placeholderString = Self.browsePlaceholder
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.delegate = self
        searchField.autoresizingMask = [.minYMargin]
        effect.addSubview(searchField)

        for y in [h - 70, 30] {
            let separator = NSBox(frame: NSRect(x: 0, y: y, width: w, height: 1))
            separator.boxType = .separator
            separator.autoresizingMask = [y > 100 ? .minYMargin : .maxYMargin]
            effect.addSubview(separator)
            horizontalSeparators.append(separator)
        }

        previewSeparator.boxType = .separator
        previewSeparator.frame = NSRect(x: w, y: 0, width: 1, height: h)
        previewSeparator.autoresizingMask = [.height]
        effect.addSubview(previewSeparator)

        previewView.frame = NSRect(x: w + 1, y: 0, width: Self.previewWidth - 1, height: h)
        previewView.autoresizingMask = [.height]
        previewView.autostarts = true
        previewView.shouldCloseWithWindow = false
        effect.addSubview(previewView)

        hintsBar.frame = NSRect(x: 0, y: 0, width: w, height: 30)
        hintsBar.autoresizingMask = [.maxYMargin]
        hintsBar.hints = browseHints
        effect.addSubview(hintsBar)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAutomaticRowHeights = false
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)

        scrollView.frame = NSRect(x: 0, y: 31, width: w, height: h - 101)
        scrollView.autoresizingMask = [.height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        column.width = scrollView.contentSize.width
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.sizeLastColumnToFit()
        effect.addSubview(scrollView)
        applyPreviewLayout()
    }

    // MARK: - Preview

    /// The preview takes its width from the list column; the panel itself never changes size.
    private func applyPreviewLayout() {
        previewSeparator.isHidden = !previewEnabled
        previewView.isHidden = !previewEnabled
        let total = Self.listSize.width, h = Self.listSize.height
        let listWidth = previewEnabled ? total - Self.previewWidth : total
        pathLabel.frame.size.width = listWidth - 32
        searchField.frame.size.width = listWidth - 28
        for separator in horizontalSeparators { separator.frame.size.width = listWidth }
        hintsBar.frame.size.width = listWidth
        hintsBar.needsDisplay = true
        if case .browse = mode, query.isEmpty { setStatus(stats) }
        scrollView.frame.size.width = listWidth
        scrollView.tile()
        tableView.frame.size.width = scrollView.contentSize.width
        tableView.sizeLastColumnToFit()
        previewSeparator.frame = NSRect(x: listWidth, y: 0, width: 1, height: h)
        previewView.frame = NSRect(x: listWidth + 1, y: 0, width: Self.previewWidth - 1, height: h)
        if previewEnabled { schedulePreviewUpdate(delay: 0) } else { previewView.previewItem = nil }
    }

    private func togglePreview() {
        previewEnabled.toggle()
        UserDefaults.standard.set(previewEnabled, forKey: Self.previewKey)
        applyPreviewLayout()
    }

    private func schedulePreviewUpdate(delay: TimeInterval = 0.08) {
        previewUpdate?.cancel()
        guard previewEnabled else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let url = self.selectedBrowsePath.map { URL(fileURLWithPath: $0) }
            if (self.previewView.previewItem as? URL) != url {
                self.previewView.previewItem = url as QLPreviewItem?
            }
        }
        previewUpdate = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        schedulePreviewUpdate()
    }

    // MARK: - Navigation

    private func navigate(to path: String, selecting name: String? = nil) {
        let t0 = Perf.now()
        setStatus("Loading…")
        loader.load(path, includeHidden: includeHidden) { [weak self] result in
            guard let self, case .browse = self.mode else { return }
            switch result {
            case .success(let listing):
                self.listing = listing
                self.currentPath = path
                UserDefaults.standard.set(path, forKey: Self.lastDirectoryKey)
                self.pathLabel.stringValue = self.displayPath(path)
                self.stats = String(format: "%d items · %.2f ms", listing.count, listing.readMilliseconds + listing.sortMilliseconds)
                self.setStatus(self.stats)
                self.clearQuery()
                self.selectionMode = false
                self.marked = []
                self.hintsBar.hints = self.browseHints
                self.tableView.reloadData()
                let row = name.flatMap { listing.index(ofName: $0) } ?? 0
                if listing.count > 0 { self.selectRow(row) }
                Perf.report("navigate", since: t0)
            case .failure(let error):
                self.setStatus("\(self.displayPath(path)): \(error)")
            }
        }
    }

    private func reload(selecting name: String?) {
        navigate(to: currentPath, selecting: name)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func setStatus(_ text: String) {
        hintsBar.status = previewEnabled && text == stats ? String(text.prefix { $0 != "·" }).trimmingCharacters(in: .whitespaces) : text
    }

    // MARK: - Filtering

    private func clearQuery() {
        query = ""
        searchField.stringValue = ""
        matches = nil
        showCreateRows = false
        filterGeneration += 1
    }

    func controlTextDidChange(_ notification: Notification) {
        if case .rename = mode { return }
        query = searchField.stringValue
        applyFilter()
    }

    private func applyFilter() {
        filterGeneration += 1
        let gen = filterGeneration
        guard let listing, !query.isEmpty else {
            matches = nil
            showCreateRows = false
            tableView.reloadData()
            if rowCount > 0 { selectRow(0) }
            return
        }
        let q = query
        let t0 = Perf.now()
        workQueue.async { [weak self] in
            let (indices, exact) = listing.filter(query: q)
            DispatchQueue.main.async {
                guard let self, gen == self.filterGeneration else { return }
                self.matches = indices
                if case .browse = self.mode { self.showCreateRows = !exact && !q.contains("/") }
                self.tableView.reloadData()
                if self.rowCount > 0 { self.selectRow(0) }
                self.setStatus("\(indices.count) of \(listing.count)")
                Perf.report("filter", since: t0)
            }
        }
    }

    private var rowCount: Int {
        let base = matches?.count ?? listing?.count ?? 0
        return base + (showCreateRows ? 2 : 0)
    }

    private func row(at index: Int) -> Row? {
        guard index >= 0, index < rowCount else { return nil }
        let base = matches?.count ?? listing?.count ?? 0
        if index < base { return .entry(matches.map { Int($0[index]) } ?? index) }
        return index == base ? .createFolder : .createFile
    }

    // MARK: - Selection

    private func selectRow(_ row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func moveSelection(by delta: Int) {
        guard rowCount > 0 else { return }
        selectRow(min(max(tableView.selectedRow + delta, 0), rowCount - 1))
    }

    private var visibleRows: Int { max(1, Int(scrollView.contentSize.height / tableView.rowHeight) - 1) }

    private var selectedEntryIndex: Int? {
        if case .entry(let i)? = row(at: tableView.selectedRow) { return i }
        return nil
    }

    /// Filesystem path of the selected browse entry. Nil in picker and rename modes.
    private var selectedBrowsePath: String? {
        guard case .browse = mode, let listing, let i = selectedEntryIndex else { return nil }
        return listing.fullPath(at: i)
    }

    private func isNavigableDirectory(entry i: Int) -> Bool {
        guard let listing else { return false }
        if listing.isDirectory(at: i) { return true }
        guard listing.isSymlink(at: i) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: listing.fullPath(at: i), isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -visibleRows)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: visibleRows)
        case #selector(NSResponder.insertNewline(_:)):
            if case .rename(let target, _) = mode { commitRename(target) } else { activateSelection() }
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            guard case .browse = mode else { return false }
            toggleMarkOnSelection(advance: selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1)
        case #selector(NSResponder.cancelOperation(_:)):
            switch mode {
            case .browse where selectionMode: exitSelectionMode()
            case .browse where !query.isEmpty: clearQuery(); applyFilter()
            case .picker where !query.isEmpty: clearQuery(); applyFilter()
            case .browse: hide()
            case .picker, .rename: leaveMode()
            }
        case #selector(NSResponder.moveRight(_:)):
            guard case .browse = mode, textView.selectedRange().location == textView.string.utf16.count,
                  let i = selectedEntryIndex, isNavigableDirectory(entry: i), let listing else { return false }
            navigate(to: listing.fullPath(at: i))
        case #selector(NSResponder.moveLeft(_:)):
            guard case .browse = mode, query.isEmpty else { return false }
            goToParent()
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            guard case .browse = mode else { return false }
            goToParent()
        default:
            return false
        }
        return true
    }

    private func handleCommand(_ selector: Selector) -> Bool {
        guard let editor = panel.fieldEditor(false, for: searchField) as? NSTextView else { return false }
        switch selector {
        case #selector(NSText.copy(_:)):
            if editor.selectedRange().length > 0 { editor.copy(nil) } else { copySelectedPath(homeRelative: false) }
        case Selector(("copyHomeRelativePath:")):
            copySelectedPath(homeRelative: true)
        case Selector(("openWith:")):
            if let path = selectedBrowsePath { enterOpenWith(target: path) }
        case Selector(("showActions:")):
            if selectionMode, !marked.isEmpty { showBatchActions() } else { showActions() }
        case Selector(("toggleSelectionMode:")):
            if selectionMode { exitSelectionMode() } else { enterSelectionMode() }
        case Selector(("openSettings:")):
            openSettings?()
        case Selector(("togglePreview:")):
            togglePreview()
        case Selector(("renameSelection:")):
            if let path = selectedBrowsePath { enterRename(target: path) }
        case Selector(("duplicateSelection:")):
            if let path = selectedBrowsePath { duplicate(path) }
        case Selector(("pasteIntoPreviousApp:")):
            if let path = selectedBrowsePath { pasteIntoPreviousApp(path) }
        case #selector(NSText.paste(_:)):
            let urls = FileOperations.pasteboardFileURLs()
            if case .browse = mode, !urls.isEmpty { pasteFiles(urls) } else { editor.paste(nil) }
        case #selector(NSText.selectAll(_:)):
            if selectionMode { markAllVisible() } else { editor.selectAll(nil) }
        case #selector(NSText.cut(_:)):
            editor.cut(nil)
        default:
            return false
        }
        return true
    }

    @objc private func activateSelection() {
        guard let listing, let row = row(at: tableView.selectedRow) else { return }
        switch (mode, row) {
        case (.picker(let picker, _), .entry(let i)):
            picker.select(i)
        case (.picker, _), (.rename, _):
            return
        case (.browse, .entry(let i)):
            let path = listing.fullPath(at: i)
            if isNavigableDirectory(entry: i) {
                navigate(to: path)
            } else {
                hide()
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        case (.browse, .createFolder):
            create(name: query, directory: true)
        case (.browse, .createFile):
            create(name: query, directory: false)
        }
    }

    private func goToParent() {
        guard currentPath != "/" else { return }
        let url = URL(fileURLWithPath: currentPath)
        navigate(to: url.deletingLastPathComponent().path, selecting: url.lastPathComponent)
    }

    // MARK: - Modes

    private func saveBrowseState() -> BrowseState? {
        guard case .browse = mode, let listing else { return nil }
        return BrowseState(listing: listing, row: tableView.selectedRow, query: query, matches: matches,
                           showCreateRows: showCreateRows, scrollOrigin: scrollView.contentView.bounds.origin)
    }

    private func enterPicker(_ picker: Picker) {
        guard let saved = saveBrowseState() else { return }
        mode = .picker(picker, saved: saved)
        listing = picker.listing
        pathLabel.stringValue = picker.title
        searchField.placeholderString = picker.placeholder
        hintsBar.hints = picker.hints
        clearQuery()
        tableView.reloadData()
        if rowCount > 0 { selectRow(0) }
        setStatus("\(picker.listing.count) items")
    }

    private func leaveMode() {
        let saved: BrowseState
        switch mode {
        case .browse: return
        case .picker(_, let state), .rename(_, let state): saved = state
        }
        mode = .browse
        listing = saved.listing
        pathLabel.stringValue = displayPath(currentPath)
        searchField.placeholderString = Self.browsePlaceholder
        hintsBar.hints = browseHints
        filterGeneration += 1
        query = saved.query
        searchField.stringValue = saved.query
        searchField.currentEditor()?.selectedRange = NSRange(location: saved.query.utf16.count, length: 0)
        matches = saved.matches
        showCreateRows = saved.showCreateRows
        tableView.reloadData()
        scrollView.contentView.scroll(to: saved.scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if rowCount > 0 { tableView.selectRowIndexes(IndexSet(integer: min(max(saved.row, 0), rowCount - 1)), byExtendingSelection: false) }
        setStatus(saved.query.isEmpty ? stats : "\(saved.matches?.count ?? 0) of \(saved.listing.count)")
    }

    // MARK: - Selection mode

    private func enterSelectionMode() {
        guard case .browse = mode else { return }
        selectionMode = true
        marked = []
        hintsBar.hints = browseHints
        reloadVisibleCells()
        updateSelectionStatus()
    }

    private func exitSelectionMode() {
        selectionMode = false
        marked = []
        hintsBar.hints = browseHints
        reloadVisibleCells()
        setStatus(query.isEmpty ? stats : "\(matches?.count ?? 0) of \(listing?.count ?? 0)")
    }

    private func toggleMarkOnSelection(advance: Int) {
        if !selectionMode { enterSelectionMode() }
        if let i = selectedEntryIndex {
            if marked.contains(i) { marked.remove(i) } else { marked.insert(i) }
            tableView.reloadData(forRowIndexes: IndexSet(integer: tableView.selectedRow), columnIndexes: IndexSet(integer: 0))
        }
        moveSelection(by: advance)
        updateSelectionStatus()
    }

    private func markAllVisible() {
        for row in 0..<rowCount {
            if case .entry(let i)? = self.row(at: row) { marked.insert(i) }
        }
        reloadVisibleCells()
        updateSelectionStatus()
    }

    private func updateSelectionStatus() {
        setStatus("\(marked.count) selected")
    }

    private func reloadVisibleCells() {
        guard rowCount > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(0..<rowCount), columnIndexes: IndexSet(integer: 0))
    }

    private var markedPaths: [String] {
        guard let listing else { return [] }
        return marked.sorted().map { listing.fullPath(at: $0) }
    }

    private func showBatchActions() {
        guard case .browse = mode else { return }
        let paths = markedPaths
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let count = paths.count
        let actions: [Action] = [
            Action(title: "Open \(count) items", symbol: "arrow.up.forward.app") { [weak self] in
                self?.hide(); for url in urls { NSWorkspace.shared.open(url) }
            },
            Action(title: "Open With…", symbol: "square.grid.2x2") { [weak self] in self?.enterOpenWith(targets: paths) },
            Action(title: "Reveal in Finder", symbol: "magnifyingglass") { [weak self] in
                self?.hide(); FileOperations.revealInFinder(paths)
            },
            Action(title: "Duplicate", symbol: "plus.square.on.square") { [weak self] in
                self?.run("Duplicate") { var first: String?; for p in paths { let n = try FileOperations.duplicate(p); first = first ?? n }; return first }
            },
            Action(title: "Copy", symbol: "doc.on.doc") { [weak self] in
                FileOperations.copyToPasteboard(paths); self?.setStatus("Copied \(count) items")
            },
            Action(title: "Paste into \(previousApp?.localizedName ?? "previous app")", symbol: "arrow.up.doc.on.clipboard") { [weak self] in
                self?.pasteIntoPreviousApp(paths)
            },
            Action(title: "Copy Paths", symbol: "link") { [weak self] in self?.copyText(paths.joined(separator: "\n")) },
            Action(title: "Copy ~ Paths", symbol: "house") { [weak self] in
                guard let self else { return }
                self.copyText(paths.map { self.displayPath($0) }.joined(separator: "\n"))
            },
            Action(title: "Move \(count) items to Trash", symbol: "trash") { [weak self] in
                self?.run("Trash") { for p in paths { try FileOperations.trash(p) }; return nil }
            },
        ]
        let icons = actions.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) ?? fileIcon }
        enterPicker(Picker(
            title: "Actions for \(count) selected items",
            placeholder: "Search actions",
            hints: [Hint(key: "↵", label: "run"), Hint(key: "esc", label: "back")],
            listing: .synthetic(actions.map(\.title)),
            icon: { icons[$0] },
            select: { [weak self] i in
                self?.leaveMode()
                actions[i].run()
            }))
    }

    private func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        setStatus("Copied")
    }

    private func showActions() {
        guard case .browse = mode, let path = selectedBrowsePath else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let actions: [Action] = [
            Action(title: "Open", symbol: "arrow.up.forward.app") { [weak self] in
                self?.hide(); NSWorkspace.shared.open(URL(fileURLWithPath: path))
            },
            Action(title: "Open With…", symbol: "square.grid.2x2") { [weak self] in self?.enterOpenWith(target: path) },
            Action(title: "Reveal in Finder", symbol: "magnifyingglass") { [weak self] in
                self?.hide(); FileOperations.revealInFinder(path)
            },
            Action(title: "Rename…", symbol: "pencil") { [weak self] in self?.enterRename(target: path) },
            Action(title: "Duplicate", symbol: "plus.square.on.square") { [weak self] in self?.duplicate(path) },
            Action(title: "Copy", symbol: "doc.on.doc") { [weak self] in
                FileOperations.copyToPasteboard(path); self?.setStatus("Copied \(name)")
            },
            Action(title: "Paste into \(previousApp?.localizedName ?? "previous app")", symbol: "arrow.up.doc.on.clipboard") { [weak self] in
                self?.pasteIntoPreviousApp(path)
            },
            Action(title: "Paste Here", symbol: "doc.on.clipboard") { [weak self] in
                self?.pasteFiles(FileOperations.pasteboardFileURLs())
            },
            Action(title: "Copy Path", symbol: "link") { [weak self] in self?.copySelectedPath(homeRelative: false, path: path) },
            Action(title: "Copy ~ Path", symbol: "house") { [weak self] in self?.copySelectedPath(homeRelative: true, path: path) },
            Action(title: "Move to Trash", symbol: "trash") { [weak self] in self?.trash(path) },
        ]
        let icons = actions.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) ?? fileIcon }
        enterPicker(Picker(
            title: "Actions for “\(name)”",
            placeholder: "Search actions",
            hints: [Hint(key: "↵", label: "run"), Hint(key: "esc", label: "back")],
            listing: .synthetic(actions.map(\.title)),
            icon: { icons[$0] },
            select: { [weak self] i in
                self?.leaveMode()
                actions[i].run()
            }))
    }

    private func enterOpenWith(target: String) { enterOpenWith(targets: [target]) }

    private func enterOpenWith(targets: [String]) {
        let target = targets.first ?? ""
        if case .picker = mode { leaveMode() }
        guard case .browse = mode, let browse = listing else { return }
        setStatus("Scanning applications…")
        workQueue.async { [weak self] in
            let apps = ApplicationList.scan()
            DispatchQueue.main.async {
                guard let self, case .browse = self.mode, self.listing === browse else { return }
                self.enterPicker(Picker(
                    title: targets.count == 1 ? "Open “\(URL(fileURLWithPath: target).lastPathComponent)” with" : "Open \(targets.count) items with",
                    placeholder: "Search applications",
                    hints: [Hint(key: "↵", label: "open with selected app"), Hint(key: "esc", label: "back")],
                    listing: apps.listing,
                    icon: { [weak self] i in self?.cachedIcon(forFile: apps.path(at: i)) ?? NSImage() },
                    select: { [weak self] i in
                        self?.leaveMode()
                        self?.hide()
                        NSWorkspace.shared.open(targets.map { URL(fileURLWithPath: $0) }, withApplicationAt: URL(fileURLWithPath: apps.path(at: i)),
                                                configuration: NSWorkspace.OpenConfiguration())
                    }))
            }
        }
    }

    private func enterRename(target: String) {
        if case .picker = mode { leaveMode() }
        guard let saved = saveBrowseState() else { return }
        let url = URL(fileURLWithPath: target)
        mode = .rename(target: target, saved: saved)
        pathLabel.stringValue = "Rename “\(url.lastPathComponent)”"
        hintsBar.hints = [Hint(key: "↵", label: "rename"), Hint(key: "esc", label: "cancel")]
        matches = nil
        showCreateRows = false
        tableView.reloadData()
        searchField.stringValue = url.lastPathComponent
        panel.makeFirstResponder(searchField)
        let stem = url.pathExtension.isEmpty ? url.lastPathComponent.utf16.count
                                             : url.lastPathComponent.utf16.count - url.pathExtension.utf16.count - 1
        searchField.currentEditor()?.selectedRange = NSRange(location: 0, length: stem)
    }

    private func commitRename(_ target: String) {
        let newName = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let oldName = URL(fileURLWithPath: target).lastPathComponent
        guard !newName.isEmpty, newName != oldName, !newName.contains("/") else { leaveMode(); return }
        leaveMode()
        run("Rename") { _ = try FileOperations.rename(target, to: newName); return newName }
    }

    // MARK: - File operations

    private func run(_ label: String, _ op: @escaping () throws -> String?) {
        let dir = currentPath
        workQueue.async { [weak self] in
            let outcome = Result { try op() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let name):
                    if self.currentPath == dir { self.reload(selecting: name) }
                case .failure(let error):
                    self.setStatus("\(label) failed: \(FileOperations.describe(error))")
                }
            }
        }
    }

    private func create(name: String, directory: Bool) {
        let path = currentPath == "/" ? "/" + name : currentPath + "/" + name
        run("Create") {
            if directory {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            } else {
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                close(fd)
            }
            return name
        }
    }

    private func trash(_ path: String) {
        let neighbor = neighborName(of: tableView.selectedRow)
        run("Trash") { try FileOperations.trash(path); return neighbor }
    }

    private func neighborName(of row: Int) -> String? {
        guard let listing else { return nil }
        for candidate in [row + 1, row - 1] {
            if case .entry(let i)? = self.row(at: candidate) { return listing.name(at: i) }
        }
        return nil
    }

    private func duplicate(_ path: String) {
        run("Duplicate") { try FileOperations.duplicate(path) }
    }

    private func pasteFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { setStatus("Clipboard has no files"); return }
        let dir = currentPath
        run("Paste") { try FileOperations.paste(urls, into: dir) }
    }

    private func pasteIntoPreviousApp(_ path: String) { pasteIntoPreviousApp([path]) }

    private func pasteIntoPreviousApp(_ paths: [String]) {
        FileOperations.copyToPasteboard(paths)
        hide()
        guard let app = previousApp, !app.isTerminated else { return }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            FileOperations.sendPasteKeystroke()
        }
    }

    private func copySelectedPath(homeRelative: Bool, path explicit: String? = nil) {
        guard let path = explicit ?? selectedBrowsePath else { return }
        let text = homeRelative ? displayPath(path) : path
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        setStatus("Copied \(text)")
    }

    // MARK: - Table

    private func cachedIcon(forFile path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    private func icon(forEntry i: Int, in listing: DirectoryListing) -> NSImage {
        if case .picker(let picker, _) = mode { return picker.icon(i) }
        return listing.isDirectory(at: i) ? folderIcon : listing.isSymlink(at: i) ? linkIcon : fileIcon
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("Row")
        if let v = tableView.makeView(withIdentifier: id, owner: nil) as? EmphasizedRowView { return v }
        let v = EmphasizedRowView()
        v.identifier = id
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
        guard let listing, let row = row(at: rowIndex) else { return nil }
        let cell = tableView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView
            ?? { let c = FileCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: tableView.rowHeight)); c.identifier = FileCellView.identifier; return c }()
        switch row {
        case .entry(let i):
            let markState: MarkState = selectionMode && { if case .browse = mode { return true } else { return false } }()
                ? (marked.contains(i) ? .marked : .unmarked) : .hidden
            cell.configure(name: listing.name(at: i), image: icon(forEntry: i, in: listing), mark: markState)
        case .createFolder:
            cell.configure(name: "Create folder “\(query)”", image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)!, secondary: true)
        case .createFile:
            cell.configure(name: "Create file “\(query)”", image: NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)!, secondary: true)
        }
        return cell
    }
}

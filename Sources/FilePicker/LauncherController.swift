import AppKit
import FSEngine
import UniformTypeIdentifiers

final class LauncherController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let lastDirectoryKey = "lastDirectory"
    private static let panelSize = NSSize(width: 680, height: 460)
    private static let hints = "↵ open   → enter   ← back   ⌘C copy path   ⌘⇧O open with   esc close"

    private enum Row {
        case entry(Int)
        case createFolder
        case createFile
    }

    private var panel: LauncherPanel!
    private let pathLabel = NSTextField(labelWithString: "")
    private let searchField = NSTextField()
    private let hintsLabel = NSTextField(labelWithString: hints)
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private let loader = DirectoryLoader()
    private let workQueue = DispatchQueue(label: "com.hazam.filepicker.filter", qos: .userInteractive)
    private var listing: DirectoryListing?
    private var currentPath: String
    private var includeHidden = false
    private var suppressHideOnResign = false

    private var query = ""
    private var filterGeneration: UInt64 = 0
    private var matches: [UInt32]?
    private var showCreateRows = false
    private var stats = ""

    private let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private let fileIcon = NSWorkspace.shared.icon(for: .data)
    private let linkIcon = NSWorkspace.shared.icon(for: .symbolicLink)
    private let newFolderIcon = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)!
    private let newFileIcon = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)!

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

    private func show() {
        let t0 = Perf.now()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.panelSize.width / 2,
                                     y: frame.midY - Self.panelSize.height / 2 + frame.height * 0.12))
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
        if !suppressHideOnResign { hide() }
    }

    // MARK: - UI construction

    private func buildPanel() {
        panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))
        panel.delegate = self
        panel.onCommand = { [weak self] selector in self?.handleCommand(selector) ?? false }

        let w = Self.panelSize.width, h = Self.panelSize.height
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
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
        pathLabel.autoresizingMask = [.width, .minYMargin]
        effect.addSubview(pathLabel)

        searchField.frame = NSRect(x: 14, y: h - 62, width: w - 28, height: 30)
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.placeholderString = "Search or type a new name"
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.delegate = self
        searchField.autoresizingMask = [.width, .minYMargin]
        effect.addSubview(searchField)

        let separator = NSBox(frame: NSRect(x: 0, y: h - 70, width: w, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        effect.addSubview(separator)

        let bottomSeparator = NSBox(frame: NSRect(x: 0, y: 30, width: w, height: 1))
        bottomSeparator.boxType = .separator
        bottomSeparator.autoresizingMask = [.width, .maxYMargin]
        effect.addSubview(bottomSeparator)

        hintsLabel.frame = NSRect(x: 16, y: 8, width: w * 0.62, height: 16)
        hintsLabel.font = .systemFont(ofSize: 11)
        hintsLabel.textColor = .secondaryLabelColor
        hintsLabel.autoresizingMask = [.width, .maxYMargin]
        effect.addSubview(hintsLabel)

        statusLabel.frame = NSRect(x: w * 0.62 + 16, y: 8, width: w * 0.38 - 32, height: 16)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.autoresizingMask = [.width, .maxYMargin, .minXMargin]
        effect.addSubview(statusLabel)

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
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        column.width = scrollView.contentSize.width
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.sizeLastColumnToFit()
        effect.addSubview(scrollView)
    }

    // MARK: - Navigation

    private func navigate(to path: String, selecting name: String? = nil) {
        let t0 = Perf.now()
        setStatus("Loading…")
        loader.load(path, includeHidden: includeHidden) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let listing):
                self.listing = listing
                self.currentPath = path
                UserDefaults.standard.set(path, forKey: Self.lastDirectoryKey)
                self.pathLabel.stringValue = self.displayPath(path)
                self.stats = String(format: "%d items · %.2f ms", listing.count, listing.readMilliseconds + listing.sortMilliseconds)
                self.setStatus(self.stats)
                self.clearQuery()
                self.tableView.reloadData()
                let row = name.flatMap { listing.index(ofName: $0) } ?? 0
                if listing.count > 0 { self.selectRow(row) }
                Perf.report("navigate", since: t0)
            case .failure(let error):
                self.setStatus("\(self.displayPath(path)): \(error)")
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
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
                self.showCreateRows = !exact && !q.contains("/")
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

    // MARK: - Selection and actions

    private func selectRow(_ row: Int) {
        let t0 = Perf.now()
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        Perf.report("select", since: t0)
    }

    private func moveSelection(by delta: Int) {
        guard rowCount > 0 else { return }
        let next = min(max(tableView.selectedRow + delta, 0), rowCount - 1)
        selectRow(next)
    }

    private var selectedEntryIndex: Int? {
        if case .entry(let i)? = row(at: tableView.selectedRow) { return i }
        return nil
    }

    private var selectedPath: String? {
        guard let listing, let i = selectedEntryIndex else { return nil }
        return listing.fullPath(at: i)
    }

    private func isNavigableDirectory(entry i: Int) -> Bool {
        guard let listing else { return false }
        if listing.isDirectory(at: i) { return true }
        guard listing.isSymlink(at: i) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: listing.fullPath(at: i), isDirectory: &isDir) && isDir.boolValue
    }

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
            activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty { hide() } else { clearQuery(); applyFilter() }
        case #selector(NSResponder.moveRight(_:)):
            guard textView.selectedRange().location == textView.string.utf16.count,
                  let i = selectedEntryIndex, isNavigableDirectory(entry: i), let listing else { return false }
            navigate(to: listing.fullPath(at: i))
        case #selector(NSResponder.moveLeft(_:)):
            guard query.isEmpty else { return false }
            goToParent()
        default:
            return false
        }
        return true
    }

    private var visibleRows: Int { max(1, Int(scrollView.contentSize.height / tableView.rowHeight) - 1) }

    private func handleCommand(_ selector: Selector) -> Bool {
        guard let editor = panel.fieldEditor(false, for: searchField) as? NSTextView else { return false }
        switch selector {
        case #selector(NSText.copy(_:)):
            if editor.selectedRange().length > 0 { editor.copy(nil) } else { copySelectedPath() }
        case Selector(("openWith:")):
            openSelectionWithChosenApp()
        case #selector(NSText.paste(_:)):
            editor.paste(nil)
        case #selector(NSText.selectAll(_:)):
            editor.selectAll(nil)
        case #selector(NSText.cut(_:)):
            editor.cut(nil)
        default:
            return false
        }
        return true
    }

    @objc private func activateSelection() {
        guard let listing, let row = row(at: tableView.selectedRow) else { return }
        switch row {
        case .entry(let i):
            let path = listing.fullPath(at: i)
            if isNavigableDirectory(entry: i) {
                navigate(to: path)
            } else {
                hide()
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        case .createFolder:
            create(name: query, directory: true)
        case .createFile:
            create(name: query, directory: false)
        }
    }

    private func create(name: String, directory: Bool) {
        let dir = currentPath
        let path = dir == "/" ? "/" + name : dir + "/" + name
        workQueue.async { [weak self] in
            var errno_: Int32 = 0
            if directory {
                if mkdir(path, 0o755) != 0 { errno_ = errno }
            } else {
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                if fd < 0 { errno_ = errno } else { close(fd) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if errno_ != 0 {
                    self.setStatus("Create failed: \(DirectoryError(code: errno_))")
                } else if self.currentPath == dir {
                    self.navigate(to: dir, selecting: name)
                }
            }
        }
    }

    private func goToParent() {
        guard currentPath != "/" else { return }
        let url = URL(fileURLWithPath: currentPath)
        navigate(to: url.deletingLastPathComponent().path, selecting: url.lastPathComponent)
    }

    private func copySelectedPath() {
        guard let path = selectedPath else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
        setStatus("Copied")
    }

    private func openSelectionWithChosenApp() {
        guard let path = selectedPath else { return }
        let open = NSOpenPanel()
        open.title = "Open \(URL(fileURLWithPath: path).lastPathComponent) with…"
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.allowedContentTypes = [.application]
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        open.level = .modalPanel
        suppressHideOnResign = true
        open.begin { [weak self] response in
            guard let self else { return }
            self.suppressHideOnResign = false
            guard response == .OK, let appURL = open.url else {
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(self.searchField)
                return
            }
            self.hide()
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Table

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
            let image = listing.isDirectory(at: i) ? folderIcon : listing.isSymlink(at: i) ? linkIcon : fileIcon
            cell.configure(name: listing.name(at: i), image: image)
        case .createFolder:
            cell.configure(name: "Create folder “\(query)”", image: newFolderIcon, secondary: true)
        case .createFile:
            cell.configure(name: "Create file “\(query)”", image: newFileIcon, secondary: true)
        }
        return cell
    }
}

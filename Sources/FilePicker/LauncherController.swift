import AppKit
import UniformTypeIdentifiers

final class LauncherController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let lastDirectoryKey = "lastDirectory"
    private static let panelSize = NSSize(width: 680, height: 440)

    private var panel: LauncherPanel!
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = FileTableView()
    private let scrollView = NSScrollView()

    private let loader = DirectoryLoader()
    private var listing: DirectoryListing?
    private var currentPath: String
    private var includeHidden = false
    private var suppressHideOnResign = false

    private let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private let fileIcon = NSWorkspace.shared.icon(for: .data)
    private let linkIcon = NSWorkspace.shared.icon(for: .symbolicLink)

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.lastDirectoryKey)
        currentPath = saved ?? NSHomeDirectory()
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
        let origin = NSPoint(x: frame.midX - Self.panelSize.width / 2,
                             y: frame.midY - Self.panelSize.height / 2 + frame.height * 0.12)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tableView)
        NSApp.activate(ignoringOtherApps: true)
        if tableView.selectedRow < 0, (listing?.count ?? 0) > 0 { selectRow(0) }
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

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        let w = Self.panelSize.width, h = Self.panelSize.height
        pathLabel.frame = NSRect(x: 16, y: h - 36, width: w - 32, height: 22)
        pathLabel.font = .systemFont(ofSize: 15, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.autoresizingMask = [.width, .minYMargin]
        effect.addSubview(pathLabel)

        statusLabel.frame = NSRect(x: 16, y: 8, width: w - 32, height: 16)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width, .maxYMargin]
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
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.onKeyAction = { [weak self] action in self?.handle(action) ?? false }

        scrollView.frame = NSRect(x: 0, y: 30, width: w, height: h - 76)
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
        statusLabel.stringValue = "Loading…"
        loader.load(path, includeHidden: includeHidden) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let listing):
                self.listing = listing
                self.currentPath = path
                UserDefaults.standard.set(path, forKey: Self.lastDirectoryKey)
                self.pathLabel.stringValue = self.displayPath(path)
                self.tableView.reloadData()
                let row = name.flatMap { listing.index(ofName: $0) } ?? 0
                if listing.count > 0 { self.selectRow(row) }
                self.statusLabel.stringValue = String(
                    format: "%d items · read %.2f ms · sort %.2f ms · %.0f KB",
                    listing.count, listing.readMilliseconds, listing.sortMilliseconds,
                    Double(listing.memoryBytes) / 1024)
                Perf.report("navigate", since: t0)
            case .failure(let error):
                self.statusLabel.stringValue = "\(self.displayPath(path)): \(error)"
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func selectRow(_ row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private var selectedPath: String? {
        guard let listing, tableView.selectedRow >= 0, tableView.selectedRow < listing.count else { return nil }
        return listing.fullPath(at: tableView.selectedRow)
    }

    private func isNavigableDirectory(row: Int) -> Bool {
        guard let listing else { return false }
        if listing.isDirectory(at: row) { return true }
        guard listing.isSymlink(at: row) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: listing.fullPath(at: row), isDirectory: &isDir) && isDir.boolValue
    }

    private func handle(_ action: KeyAction) -> Bool {
        switch action {
        case .escape:
            hide()
        case .enter:
            activateSelection()
        case .parent:
            goToParent()
        case .copyPath:
            copySelectedPath()
        case .openWith:
            openSelectionWithChosenApp()
        case .up, .down:
            return false
        }
        return true
    }

    @objc private func activateSelection() {
        let row = tableView.selectedRow
        guard let listing, row >= 0, row < listing.count else { return }
        let path = listing.fullPath(at: row)
        if isNavigableDirectory(row: row) {
            navigate(to: path)
        } else {
            hide()
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
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
        statusLabel.stringValue = "Copied \(path)"
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
                return
            }
            self.hide()
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { listing?.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let listing else { return nil }
        let cell = tableView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView
            ?? { let c = FileCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: tableView.rowHeight)); c.identifier = FileCellView.identifier; return c }()
        let image = listing.isDirectory(at: row) ? folderIcon : listing.isSymlink(at: row) ? linkIcon : fileIcon
        cell.configure(name: listing.name(at: row), image: image)
        return cell
    }
}

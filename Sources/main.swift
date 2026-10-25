import AppKit
import ServiceManagement

final class BackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
final class FlippedStackView: NSStackView { override var isFlipped: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private let quickPopover = NSPopover()
    private let quickController = NSViewController()
    private var floatingQuickPanel: NSPanel?
    private let menuBarStatus = NSTextField(wrappingLabelWithString: "")
    private let repairMenuButton = NSButton(title: L("Show Menu Bar Icon Again"), target: nil, action: nil)
    private let quickDirection = NSPopUpButton()
    private let quickMode = NSPopUpButton()
    private let quickStatus = NSTextField(wrappingLabelWithString: L("Ready"))
    private let quickProgress = NSProgressIndicator()
    private let quickSync = NSButton(title: L("Sync Now"), target: nil, action: nil)
    private let quickBackup = NSButton(title: L("Back Up Both"), target: nil, action: nil)
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "local.SafariFavoritesSync.work")
    private let panes = NSTabView()
    private let direction = NSPopUpButton()
    private let scheduleHint = NSTextField(wrappingLabelWithString: "")
    private let emptyBackups = NSTextField(wrappingLabelWithString: "")
    private let mode = NSPopUpButton()
    private let profile = NSPopUpButton()
    private var profileURLs: [URL] = []
    private let minutes = NSTextField(string: "5")
    private let automatic = NSButton(checkboxWithTitle: L("Scheduled sync (while Safari is closed)"), target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: L("Open at Login"), target: nil, action: nil)
    private let language = NSPopUpButton()
    private let syncButton = NSButton(title: L("Sync Bookmarks Now"), target: nil, action: nil)
    private let backupButton = NSButton(title: L("Back Up Safari Bookmarks"), target: nil, action: nil)
    private let deleteButton = NSButton(title: L("Delete Selected Backups…"), target: nil, action: nil)
    private let restoreButton = NSButton(title: L("Restore Selected Backup…"), target: nil, action: nil)
    private let previewButton = NSButton(title: L("View Backup"), target: nil, action: nil)
    private let authorizeButton = NSButton(title: L("Authorize Safari Bookmark File…"), target: nil, action: nil)
    private let sourceButton = NSButton(title: L("Choose Edge Bookmark File…"), target: nil, action: nil)
    private let checkButton = NSButton(title: L("Check Bookmarks / Retry Access"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: L("Ready. Only bookmarks are synchronized; open browser tabs are not changed."))
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let table = NSTableView()
    private var backups: [FavoritesBackup] = []
    private var timer: Timer?
    private var busy = false
    private var terminationPending = false
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SafariTabSync", isDirectory: true)
    private lazy var store = FavoritesBackupStore(directory: support.appendingPathComponent("FavoritesBackups", isDirectory: true))
    private var safariDefault: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist") }
    private var edgeDefault: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Microsoft Edge/Default/Bookmarks") }
    private var safariRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty }
    private var appIcon: NSImage? {
        Bundle.main.url(forResource: "AppIcon-v3", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = ProcessInfo.processInfo.environment["SAFARI_SYNC_THEME"].flatMap { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) }
        NSApp.applicationIconImage = appIcon
        // Tab synchronization settings must never start an unexpected bookmark mirror.
        if !defaults.bool(forKey: "favoritesMigrationV1") {
            defaults.set(false, forKey: "automatic")
            defaults.set(0, forKey: "mode")
            defaults.set(true, forKey: "favoritesMigrationV1")
        }
        buildMenus()
        buildWindow()
        reloadBackups()
        showWindow(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshMenuBarStatus() }
        if ProcessInfo.processInfo.arguments.contains("--read-only-check") {
            runReadOnlyCheck()
            return
        }
        let smoke = ProcessInfo.processInfo.arguments.contains("--ui-smoke-test")
        if smoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                precondition(self.window.isVisible)
                self.window.close()
                precondition(self.statusItem.isVisible && self.statusItem.button != nil, "Closing the main window must preserve the menu bar entry")
                self.refreshQuickPanel()
                precondition(self.quickPopover.contentViewController != nil)
                self.quickPopover.animates = false
                self.toggleQuickPanel(nil)
                precondition(self.quickPopover.isShown || self.floatingQuickPanel?.isVisible == true, "Quick controls must remain accessible even when a menu manager hides the icon")
                self.captureQuickPreview()
                self.quickPopover.performClose(nil)
                _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                precondition(self.window.isVisible && self.appIcon != nil)
                precondition(self.backupButton.superview !== self.syncButton.superview)
                self.setBusy(true)
                precondition(!self.syncButton.isEnabled && !self.progress.isHidden)
                self.updateProgress(.init(fraction: 0.65, message: L("UI test: writing…")))
                precondition(self.progress.doubleValue == 65)
                self.setBusy(false)
                precondition(self.syncButton.isEnabled && self.progress.isHidden)
                let permissionAlert = self.makePermissionAlert(FavoritesAccessError(url: self.safariDefault, writing: false))
                precondition(permissionAlert.buttons.first?.title == L("Open Full Disk Access Settings"))
                precondition(permissionAlert.buttons.count == 3)
                let savedDirection = self.direction.indexOfSelectedItem
                let savedMode = self.mode.indexOfSelectedItem
                self.status.stringValue = L("Ready. Both browsers are backed up before every sync.")
                self.window.setContentSize(NSSize(width: 720, height: 650))
                for index in 0..<3 {
                    self.selectPane(index)
                    self.window.contentView?.layoutSubtreeIfNeeded()
                    let checks: [[NSControl]] = [[self.direction, self.mode, self.syncButton, self.checkButton, self.automatic, self.minutes], [self.backupButton, self.restoreButton, self.previewButton, self.deleteButton], [self.profile, self.sourceButton, self.authorizeButton, self.login]]
                    for control in checks[index] {
                        let frame = control.convert(control.bounds, to: self.window.contentView!)
                        precondition(self.window.contentView!.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Control clipped at minimum window size")
                    }
                    self.capturePreview(["sync", "backups", "settings"][index])
                }
                self.selectPane(0)
                self.direction.selectItem(at: 1); self.mode.selectItem(at: 1); self.updateWarning()
                precondition(self.warning.stringValue.contains("Edge") && self.mode.indexOfSelectedItem == 1)
                self.capturePreview("reverse-mirror")
                self.direction.selectItem(at: savedDirection); self.mode.selectItem(at: savedMode); self.updateWarning()
                self.selectPane(2)
                _ = self.language.scrollToVisible(self.language.bounds)
                self.capturePreview("language-settings")
                _ = self.menuBarStatus.scrollToVisible(self.menuBarStatus.bounds)
                _ = self.repairMenuButton.scrollToVisible(self.repairMenuButton.bounds)
                self.window.contentView?.layoutSubtreeIfNeeded()
                let repairFrame = self.repairMenuButton.convert(self.repairMenuButton.bounds, to: self.window.contentView!)
                precondition(self.window.contentView!.bounds.contains(repairFrame), "Menu bar recovery button must be reachable by scrolling")
                self.capturePreview("menu-settings")
                self.selectPane(0)
                print("PASS: main window close preserves menu bar, quick panel, three native panes, direction/mode controls, progress, permissions and icon. No bookmarks modified.")
                NSApp.terminate(nil)
            }
        } else { configureTimer() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { terminationPending = true; status.stringValue = L("Waiting for the current operation to finish before quitting…"); return .terminateLater }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(nil); return true }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let quick = NSMenuItem(title: L("Open Quick Panel"), action: #selector(toggleQuickPanel(_:)), keyEquivalent: "")
        quick.target = self; menu.addItem(quick)
        let main = NSMenuItem(title: L("Open Main Window"), action: #selector(showWindow(_:)), keyEquivalent: "")
        main.target = self; menu.addItem(main)
        return menu
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshMenuBarStatus() }

    private func buildMenus() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let about = NSMenuItem(title: L("About Safari Bookmark Sync"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp; applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())
        let settings = NSMenuItem(title: L("Bookmark Sync and Backups…"), action: #selector(showWindow(_:)), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        let quick = NSMenuItem(title: L("Open Quick Panel"), action: #selector(toggleQuickPanel(_:)), keyEquivalent: "y")
        quick.keyEquivalentModifierMask = [.command, .shift]
        quick.target = self; applicationMenu.addItem(quick)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L("Quit Safari Bookmark Sync"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
        createStatusItem()
        buildQuickPanel()
    }
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "SafariFavoritesSyncStatusItem"
        statusItem.isVisible = true
        let icon = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: L("Bookmark Sync Quick Panel"))
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = L("Bookmark Sync — Click for Quick Actions")
        statusItem.button?.setAccessibilityLabel(L("Bookmark Sync Quick Panel"))
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleQuickPanel(_:))
    }

    private func buildQuickPanel() {
        let controller = quickController
        let content = BackgroundView(frame: NSRect(x: 0, y: 0, width: 340, height: 332))
        controller.view = content
        let root = vertical(spacing: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ])
        let title = NSTextField(labelWithString: L("Bookmark Sync"))
        title.font = .boldSystemFont(ofSize: 16)
        append(title, to: root)
        quickDirection.addItems(withTitles: ["Edge → Safari", "Safari → Edge"])
        quickMode.addItems(withTitles: [L("Incremental"), L("Mirror")])
        for control in [quickDirection, quickMode] {
            control.target = self; control.action = #selector(quickSettingsChanged(_:))
        }
        quickDirection.setAccessibilityLabel(L("Quick Panel Sync Direction"))
        quickMode.setAccessibilityLabel(L("Quick Panel Sync Mode"))
        append(quickDirection, to: root)
        append(quickMode, to: root)
        quickStatus.font = .systemFont(ofSize: 12)
        quickStatus.maximumNumberOfLines = 3
        append(quickStatus, to: root)
        quickStatus.heightAnchor.constraint(equalToConstant: 48).isActive = true
        quickProgress.style = .bar; quickProgress.minValue = 0; quickProgress.maxValue = 100
        quickProgress.isHidden = true
        append(quickProgress, to: root)
        quickSync.target = self; quickSync.action = #selector(quickSyncNow(_:)); quickSync.bezelStyle = .rounded
        quickBackup.target = self; quickBackup.action = #selector(quickBackupNow(_:)); quickBackup.bezelStyle = .rounded
        append(row([quickBackup, spacer(), quickSync]), to: root)
        let separator = NSBox(); separator.boxType = .separator
        append(separator, to: root)
        let open = NSButton(title: L("Open Main Window"), target: self, action: #selector(showWindow(_:)))
        let quit = NSButton(title: L("Quit"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        append(row([open, spacer(), quit]), to: root)
        quickPopover.contentViewController = controller
        quickPopover.contentSize = content.frame.size
        quickPopover.behavior = .transient
        quickPopover.animates = true
    }
    @objc private func toggleQuickPanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        refreshMenuBarStatus()
        if menuBarVisibility != .visible {
            if floatingQuickPanel?.isVisible == true { floatingQuickPanel?.orderOut(nil); return }
            quickPopover.performClose(nil)
            quickPopover.contentViewController = nil
            if floatingQuickPanel == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 332), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
                panel.title = L("Bookmark Sync — Quick Panel")
                panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
                floatingQuickPanel = panel
            }
            floatingQuickPanel?.contentViewController = quickController
            floatingQuickPanel?.center(); floatingQuickPanel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshQuickPanel()
            return
        }
        if quickPopover.isShown { quickPopover.performClose(nil) }
        else {
            floatingQuickPanel?.orderOut(nil)
            floatingQuickPanel?.contentViewController = nil
            quickPopover.contentViewController = quickController
            refreshQuickPanel()
            quickPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            quickPopover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func quickSettingsChanged(_ sender: Any?) {
        guard !busy else { return }
        direction.selectItem(at: quickDirection.indexOfSelectedItem)
        mode.selectItem(at: quickMode.indexOfSelectedItem)
        settingsChanged(nil)
    }
    @objc private func quickSyncNow(_ sender: Any?) { sync(manual: true) }
    @objc private func quickBackupNow(_ sender: Any?) { backupNow(nil) }
    private func refreshQuickPanel() {
        quickDirection.selectItem(at: max(0, direction.indexOfSelectedItem))
        quickMode.selectItem(at: max(0, mode.indexOfSelectedItem))
        quickStatus.stringValue = status.stringValue
        quickStatus.textColor = status.textColor
        quickStatus.toolTip = status.stringValue
        quickSync.title = mode.indexOfSelectedItem == 1 ? L("Back Up and Mirror…") : L("Sync Now")
        for control in [quickDirection, quickMode, quickSync, quickBackup] as [NSControl] { control.isEnabled = !busy }
        quickProgress.isHidden = !busy
        quickProgress.isIndeterminate = progress.isIndeterminate
        quickProgress.doubleValue = progress.doubleValue
        if busy && progress.isIndeterminate { quickProgress.startAnimation(nil) } else { quickProgress.stopAnimation(nil) }
    }
    private func captureQuickPreview() {
        guard let path = ProcessInfo.processInfo.environment["SAFARI_SYNC_PREVIEW"] else { return }
        let surface = quickController.view
        surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let base = URL(fileURLWithPath: path).deletingPathExtension().path
            try? png.write(to: URL(fileURLWithPath: base + "-quick-panel.png"))
        }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("Sync")
        window.minSize = NSSize(width: 720, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = BackgroundView(frame: NSRect(x: 0, y: 0, width: 760, height: 650))
        window.center()
        let toolbar = NSToolbar(identifier: "FavoritesPanes")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = paneIDs[0]
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        let chromeHeight = window.frame.height - window.contentView!.frame.height
        window.minSize = NSSize(width: 720, height: 650 + chromeHeight)

        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        panes.tabViewType = .noTabsNoBorder
        for (index, pane) in [makeSyncPane(), makeBackupPane(), scrollable(makeSettingsPane())].enumerated() {
            let item = NSTabViewItem(identifier: index); item.view = pane; panes.addTabViewItem(item)
        }
        root.addArrangedSubview(panes)
        panes.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        panes.setContentHuggingPriority(.defaultLow, for: .vertical)

        let divider = NSBox(); divider.boxType = .separator
        root.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.stringValue = L("Ready. Both browsers are backed up before every sync.")
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        progress.style = .bar; progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 100; progress.isHidden = true
        root.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let savedPane = min(2, max(0, defaults.integer(forKey: "selectedPane")))
        selectPane(savedPane)
        updateWarning()
    }

    private func makeSyncPane() -> NSView {
        let pane = vertical(spacing: 20)
        append(heading(L("Bookmark Sync"), detail: L("Choose a direction and mode. Folder structure is preserved.")), to: pane)
        direction.addItems(withTitles: ["Edge → Safari", "Safari → Edge"])
        direction.selectItem(at: defaults.integer(forKey: "favoritesDirection") == 1 ? 1 : 0)
        direction.target = self; direction.action = #selector(settingsChanged(_:))
        direction.setAccessibilityLabel(L("Sync Direction"))
        mode.addItems(withTitles: [L("Incremental"), L("Mirror")])
        mode.selectItem(at: defaults.integer(forKey: "mode") == 1 ? 1 : 0)
        mode.target = self; mode.action = #selector(settingsChanged(_:))
        mode.setAccessibilityLabel(L("Sync Mode"))
        direction.widthAnchor.constraint(equalToConstant: 280).isActive = true
        mode.widthAnchor.constraint(equalToConstant: 280).isActive = true
        warning.font = .systemFont(ofSize: 12)
        append(group(L("Sync Options"), views: [formRow(L("Direction"), controls: [direction]), formRow(L("Mode"), controls: [mode]), warning]), to: pane)

        automatic.title = L("Automatic Sync")
        automatic.state = defaults.bool(forKey: "automatic") ? .on : .off
        automatic.target = self; automatic.action = #selector(settingsChanged(_:))
        minutes.integerValue = max(1, defaults.integer(forKey: "favoritesMinutes") == 0 ? 5 : defaults.integer(forKey: "favoritesMinutes"))
        minutes.widthAnchor.constraint(equalToConstant: 62).isActive = true
        minutes.target = self; minutes.action = #selector(settingsChanged(_:))
        minutes.setAccessibilityLabel(L("Automatic Sync Interval in Minutes"))
        scheduleHint.font = .systemFont(ofSize: 12); scheduleHint.textColor = .secondaryLabelColor
        append(group(L("Automation"), views: [formRow(L("Schedule"), controls: [automatic]), formRow(L("Interval"), controls: [minutes, label(L("minutes"))]), scheduleHint]), to: pane)

        checkButton.title = L("Check Access")
        checkButton.target = self; checkButton.action = #selector(checkCounts(_:))
        syncButton.target = self; syncButton.action = #selector(syncNow(_:))
        syncButton.bezelStyle = .rounded; syncButton.controlSize = .large
        syncButton.bezelColor = .controlAccentColor
        let actions = row([checkButton, spacer(), syncButton])
        append(actions, to: pane)
        let configure = NSButton(title: L("Configure Browsers and Permissions…"), target: self, action: #selector(showSettingsPane(_:)))
        configure.bezelStyle = .inline
        append(row([configure, spacer()]), to: pane)
        pane.addArrangedSubview(spacer())
        return pane
    }

    private func makeBackupPane() -> NSView {
        let pane = vertical(spacing: 18)
        backupButton.title = L("Back Up Both Now")
        backupButton.target = self; backupButton.action = #selector(backupNow(_:))
        backupButton.bezelStyle = .rounded; backupButton.controlSize = .large
        backupButton.image = NSImage(systemSymbolName: "externaldrive.badge.checkmark", accessibilityDescription: L("Both Browser Backups"))
        backupButton.imagePosition = .imageLeading
        append(row([heading(L("Backups and Restore"), detail: L("Save complete Edge and Safari bookmark files for recovery.")), spacer(), backupButton]), to: pane)
        for (identifier, title, width) in [("date", L("Date"), 170.0), ("edge", "Edge", 65.0), ("safari", "Safari", 65.0), ("reason", L("Backup Reason"), 310.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = true; table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        append(scroll, to: pane)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        emptyBackups.font = .systemFont(ofSize: 12); emptyBackups.textColor = .secondaryLabelColor
        append(emptyBackups, to: pane)
        restoreButton.title = L("Restore…"); restoreButton.target = self; restoreButton.action = #selector(restoreSelected(_:))
        previewButton.title = L("View Contents"); previewButton.target = self; previewButton.action = #selector(previewSelected(_:))
        deleteButton.title = L("Delete…"); deleteButton.target = self; deleteButton.action = #selector(deleteSelected(_:))
        let folder = NSButton(title: L("Show in Finder"), target: self, action: #selector(openBackups(_:)))
        append(row([restoreButton, previewButton, spacer(), folder, deleteButton]), to: pane)
        let note = label(L("Select a backup to restore or inspect. Command-click to select multiple backups for deletion. Deleted backups go to Trash; backups are never removed automatically."), size: 12)
        note.textColor = .secondaryLabelColor
        append(note, to: pane)
        return pane
    }

    private func makeSettingsPane() -> NSView {
        let pane = vertical(spacing: 20)
        append(heading(L("Browsers and Permissions"), detail: L("Set up file access once, then start syncing.")), to: pane)
        profile.target = self; profile.action = #selector(profileChanged(_:))
        loadProfiles()
        profile.widthAnchor.constraint(equalToConstant: 300).isActive = true
        sourceButton.title = L("Choose Another Bookmark File…")
        sourceButton.target = self; sourceButton.action = #selector(selectEdge(_:))
        append(group("Microsoft Edge", views: [formRow(L("Profile"), controls: [profile]), formRow(L("Bookmark File"), controls: [sourceButton])]), to: pane)
        authorizeButton.title = L("Choose Safari Bookmark File…")
        authorizeButton.target = self; authorizeButton.action = #selector(selectSafari(_:))
        let permissions = NSButton(title: L("Open Full Disk Access Settings…"), target: self, action: #selector(openPermissions(_:)))
        let retry = NSButton(title: L("Check Access Again"), target: self, action: #selector(checkCounts(_:)))
        let hint = label(L("Safari bookmarks require file access. If access is denied, add this app in Full Disk Access and reopen it when prompted."), size: 12)
        hint.textColor = .secondaryLabelColor
        append(group(L("Safari File Access"), views: [hint, row([authorizeButton, spacer()]), row([permissions, retry, spacer()])]), to: pane)
        login.title = L("Open at Login")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self; login.action = #selector(loginChanged(_:))
        language.addItems(withTitles: [L("Follow System"), "English", L("Simplified Chinese")])
        let languageIDs = ["system", "en", "zh-Hans"]
        language.selectItem(at: languageIDs.firstIndex(of: defaults.string(forKey: "appLanguage") ?? "system") ?? 0)
        language.target = self; language.action = #selector(languageChanged(_:))
        language.widthAnchor.constraint(equalToConstant: 230).isActive = true
        append(group(L("General"), views: [login, formRow(L("Language"), controls: [language])]), to: pane)
        menuBarStatus.font = .systemFont(ofSize: 12); menuBarStatus.textColor = .secondaryLabelColor
        let restoreIcon = repairMenuButton
        restoreIcon.target = self; restoreIcon.action = #selector(restoreMenuBarIcon(_:))
        let quick = NSButton(title: L("Open Quick Panel"), target: self, action: #selector(toggleQuickPanel(_:)))
        append(group(L("Menu Bar"), views: [menuBarStatus, row([restoreIcon, quick, spacer()])]), to: pane)
        let note = label(L("Only the destination browser needs to quit. Mirror replaces all ordinary destination bookmarks. Cloud sync may propagate changes to other devices. Safari Reading List is excluded."), size: 12)
        note.textColor = .secondaryLabelColor
        append(note, to: pane)
        pane.addArrangedSubview(spacer())
        return pane
    }

    private func vertical(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; return stack
    }
    private func scrollable(_ view: NSView) -> NSView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let doc = FlippedStackView()
        doc.orientation = .vertical; doc.alignment = .leading; doc.spacing = 0
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        append(view, to: doc)
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        ])
        return scroll
    }
    @objc private func languageChanged(_ sender: Any?) {
        guard !busy else { return }
        let IDs = ["system", "en", "zh-Hans"]
        let previous = defaults.string(forKey: "appLanguage") ?? "system"
        let previousAppleLanguages = defaults.object(forKey: "AppleLanguages")
        let selected = IDs[language.indexOfSelectedItem]
        guard selected != previous else { return }
        guard confirm(L("Reopen to Change Language?"), L("The app needs to reopen to apply the language. Bookmarks and backups will not change."), action: L("Reopen")) else {
            language.selectItem(at: IDs.firstIndex(of: previous) ?? 0); return
        }
        defaults.set(selected, forKey: "appLanguage")
        if selected == "system" { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([selected], forKey: "AppleLanguages") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.defaults.set(previous, forKey: "appLanguage")
                    if let previousAppleLanguages = previousAppleLanguages { self.defaults.set(previousAppleLanguages, forKey: "AppleLanguages") }
                    else { self.defaults.removeObject(forKey: "AppleLanguages") }
                    self.showError(error)
                }
                else { NSApp.terminate(nil) }
            }
        }
    }
    private func append(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); view.setContentHuggingPriority(.defaultLow, for: .vertical); return view
    }
    private func heading(_ title: String, detail: String) -> NSView {
        let stack = vertical(spacing: 5)
        let titleView = label(title, size: 20); titleView.font = .boldSystemFont(ofSize: 20)
        let detailView = label(detail, size: 12); detailView.textColor = .secondaryLabelColor
        append(titleView, to: stack); append(detailView, to: stack)
        return stack
    }
    private func formRow(_ name: String, controls: [NSView]) -> NSView {
        let title = NSTextField(labelWithString: name)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let stack = row([title] + controls + [spacer()]); stack.alignment = .centerY
        return stack
    }
    private func group(_ title: String, views: [NSView]) -> NSView {
        let outer = vertical(spacing: 8)
        let titleView = label(title, size: 13); titleView.font = .boldSystemFont(ofSize: 13)
        append(titleView, to: outer)
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle
        box.borderColor = .separatorColor; box.borderWidth = 0.5
        box.fillColor = .controlBackgroundColor; box.cornerRadius = 8
        box.contentViewMargins = .zero
        let content = vertical(spacing: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -16)
        ])
        for view in views { append(view, to: content) }
        append(box, to: outer)
        return outer
    }

    private let paneIDs = [NSToolbarItem.Identifier("sync"), NSToolbarItem.Identifier("backups"), NSToolbarItem.Identifier("settings")]
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { paneIDs }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { paneIDs }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { paneIDs }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let index = paneIDs.firstIndex(of: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = [L("Sync"), L("Backups"), L("Settings")][index]
        item.image = NSImage(systemSymbolName: ["arrow.triangle.2.circlepath", "externaldrive", "gearshape"][index], accessibilityDescription: item.label)
        item.target = self; item.action = #selector(toolbarSelected(_:)); item.tag = index
        return item
    }
    @objc private func toolbarSelected(_ sender: NSToolbarItem) { selectPane(sender.tag) }
    @objc private func showSettingsPane(_ sender: Any?) { selectPane(2) }
    private func selectPane(_ index: Int) {
        panes.selectTabViewItem(at: index)
        window.toolbar?.selectedItemIdentifier = paneIDs[index]
        window.title = [L("Sync"), L("Backups and Restore"), L("Browsers and Permissions")][index]
        syncButton.keyEquivalent = index == 0 ? "\r" : ""
        defaults.set(index, forKey: "selectedPane")
    }
    private func capturePreview(_ name: String) {
        guard let path = ProcessInfo.processInfo.environment["SAFARI_SYNC_PREVIEW"], let surface = window.contentView?.superview else { return }
        surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let base = URL(fileURLWithPath: path).deletingPathExtension().path
            try? png.write(to: URL(fileURLWithPath: base + "-" + name + ".png"))
        }
    }
    private func runReadOnlyCheck() {
        let edgeURL = sourceURL, safariURL = targetURL
        queue.async {
            do {
                try self.withAccess([edgeURL, safariURL]) {
                    let edgeBytes = try FavoritesEngine.read(edgeURL), safariBytes = try FavoritesEngine.read(safariURL)
                    let edge = try EdgeFavorites(data: edgeBytes), safari = try SafariFavorites(data: safariBytes)
                    let document = try EdgeBookmarkDocument(data: edgeBytes)
                    for mode in [SyncMode.incremental, .mirror] {
                        if edge.count > 0 {
                            let result = try SafariFavorites(data: safari.applying(edge, mode: mode))
                            print("READ ONLY Edge → Safari \(mode): source=\(edge.count), targetBefore=\(safari.count), plannedAfter=\(result.count)")
                        }
                        if safari.count > 0 {
                            let result = try EdgeFavorites(data: document.applying(safari.exported(), mode: mode))
                            print("READ ONLY Safari → Edge \(mode): source=\(safari.count), targetBefore=\(edge.count), plannedAfter=\(result.count)")
                        }
                    }
                    print("Real file formats validated in memory. No browser bookmarks were written or browsers closed.")
                }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                FileHandle.standardError.write(Data(("READ ONLY check unavailable: " + error.localizedDescription + "\n").utf8))
                DispatchQueue.main.async { exit(2) }
            }
        }
    }

    private func label(_ text: String, size: CGFloat = 13) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size); return field
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; return stack
    }
    @objc private func showWindow(_ sender: Any?) {
        quickPopover.performClose(nil)
        floatingQuickPanel?.orderOut(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private var menuBarVisibility: MenuBarVisibility {
        MenuBarVisibility.classify(item: statusItem?.button?.window?.frame,
            screens: NSScreen.screens.map { ($0.frame, $0.auxiliaryTopLeftArea, $0.auxiliaryTopRightArea) })
    }
    private func refreshMenuBarStatus() {
        guard statusItem != nil else { return }
        switch menuBarVisibility {
        case .visible: menuBarStatus.stringValue = L("The menu bar icon is on screen. Click the circular arrows after closing the main window.")
        case .offscreen: menuBarStatus.stringValue = L("The icon exists but is off screen. If you use Bartender, set this app to Show. The Quick Panel is also available from the Dock menu.")
        case .behindNotch: menuBarStatus.stringValue = L("The icon is behind the notch. Show it again, or move it to the right in your menu bar manager.")
        case .unavailable: menuBarStatus.stringValue = L("The menu bar entry is not ready. Show the icon again, or open the Quick Panel from the Dock menu.")
        }
    }
    @objc private func restoreMenuBarIcon(_ sender: Any?) {
        quickPopover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
        defaults.set(0, forKey: "NSStatusItem Preferred Position SafariFavoritesSyncStatusItem")
        createStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.refreshMenuBarStatus()
            if self.menuBarVisibility != .visible {
                self.showError(SyncFailure.message(L("A menu bar manager is still hiding the icon. In Bartender, move this app from Always Hide to Show. You can also open the Quick Panel from the Dock menu.")))
            }
        }
    }

    private func scopedURL(_ key: String, fallback: URL) -> URL {
        if let data = defaults.data(forKey: key) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
                if stale { saveAccess(url, key: key) }
                return url
            }
        }
        return defaults.string(forKey: key + "Path").map { URL(fileURLWithPath: $0) } ?? fallback
    }
    private func saveAccess(_ url: URL, key: String) {
        defaults.set(url.path, forKey: key + "Path")
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) { defaults.set(data, forKey: key) }
    }
    private var targetURL: URL { scopedURL("favoritesSafariAccess", fallback: safariDefault) }
    private var sourceURL: URL { scopedURL("favoritesEdgeAccess", fallback: profileURLs.indices.contains(profile.indexOfSelectedItem) ? profileURLs[profile.indexOfSelectedItem] : edgeDefault) }
    private func withAccess<T>(_ urls: [URL], work: () throws -> T) rethrows -> T {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try work()
    }
    private func loadProfiles() {
        let folder = edgeDefault.deletingLastPathComponent().deletingLastPathComponent()
        let paths = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        profileURLs = paths.map { $0.appendingPathComponent("Bookmarks") }.filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
        if profileURLs.isEmpty { profileURLs = [edgeDefault] }
        let state = (try? Data(contentsOf: folder.appendingPathComponent("Local State"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cache = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] ?? [:]
        profile.addItems(withTitles: profileURLs.map { url in
            let name = url.deletingLastPathComponent().lastPathComponent
            return (cache[name]?["name"] as? String ?? name) + " (" + name + ")"
        })
        if let path = defaults.string(forKey: "favoritesProfile"), let index = profileURLs.firstIndex(where: { $0.path == path }) { profile.selectItem(at: index) }
    }
    @objc private func profileChanged(_ sender: Any?) {
        defaults.removeObject(forKey: "favoritesEdgeAccess")
        defaults.removeObject(forKey: "favoritesEdgeAccessPath")
        defaults.set(sourceURL.path, forKey: "favoritesProfile")
        status.stringValue = L("Edge profile selected. Click Check Access to verify it.")
    }
    @objc private func selectEdge(_ sender: Any?) { chooseFile(title: L("Choose the Bookmarks File in Your Edge Profile"), expectedName: "Bookmarks", fallback: sourceURL, key: "favoritesEdgeAccess") }
    @objc private func selectSafari(_ sender: Any?) { chooseFile(title: L("Authorize Safari’s Original Bookmarks.plist File"), expectedName: "Bookmarks.plist", fallback: safariDefault, key: "favoritesSafariAccess") }
    @objc private func openPermissions(_ sender: Any?) {
        status.stringValue = L("In Full Disk Access, click +, add Safari Bookmark Sync, and enable it. Reopen this app when prompted, then click Check Access.")
        refreshQuickPanel()
        let primary = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if !NSWorkspace.shared.open(primary) {
            let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!
            if !NSWorkspace.shared.open(fallback) {
                showError(SyncFailure.message(L("Could not open System Settings. Open System Settings → Privacy & Security → Full Disk Access manually.")))
            }
        }
    }
    private func chooseFile(title: String, expectedName: String, fallback: URL, key: String) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = title; panel.message = L("Select %1$@\nAccess is used only to read, back up, and synchronize bookmarks." , fallback.path)
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.directoryURL = fallback.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard url.lastPathComponent == expectedName else { self.showError(SyncFailure.message(L("Choose the %1$@ file." , expectedName))); return }
            if key == "favoritesSafariAccess", url.resolvingSymlinksInPath() != self.safariDefault.resolvingSymlinksInPath() {
                self.showError(SyncFailure.message(L("Select Safari’s original file at %1$@, not an exported backup copy." , self.safariDefault.path))); return
            }
            self.saveAccess(url, key: key)
            self.status.stringValue = L("Access granted to %1$@. Click Check Access." , url.lastPathComponent)
        }
    }

    @objc private func settingsChanged(_ sender: Any?) {
        minutes.integerValue = min(1440, max(1, minutes.integerValue))
        defaults.set(mode.indexOfSelectedItem, forKey: "mode")
        defaults.set(direction.indexOfSelectedItem, forKey: "favoritesDirection")
        defaults.set(minutes.integerValue, forKey: "favoritesMinutes")
        defaults.set(automatic.state == .on, forKey: "automatic")
        updateWarning(); configureTimer()
    }
    private func updateWarning() {
        let mirror = mode.indexOfSelectedItem == 1
        let target = selectedDirection == .edgeToSafari ? "Safari" : "Edge"
        warning.stringValue = mirror ? L("Replace all ordinary %1$@ bookmarks. Both browsers are backed up first; an empty source is never applied." , target) : L("Keep existing %1$@ bookmarks and merge matching folders. Exact URLs are deduplicated within each folder." , target)
        warning.textColor = mirror ? .systemOrange : .secondaryLabelColor
        syncButton.title = mirror ? L("Back Up and Mirror…") : L("Sync Now")
        scheduleHint.stringValue = L("Runs automatically only while destination %1$@ is closed. Browsers are never quit automatically." , target)
        minutes.isEnabled = !busy && automatic.state == .on
        refreshQuickPanel()
    }

    private func configureTimer() {
        timer?.invalidate(); timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        if automatic.state == .on {
            timer = Timer.scheduledTimer(withTimeInterval: Double(max(1, minutes.integerValue) * 60), repeats: true) { [weak self] _ in self?.sync(manual: false) }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        }
    }
    @objc private func didWake(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.automatic.state == .on else { return }
            self.sync(manual: false)
        }
    }
    @objc private func loginChanged(_ sender: Any?) {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; showError(error) }
    }
    @objc private func checkCounts(_ sender: Any?) {
        let source = sourceURL, target = targetURL
        perform(title: L("Bookmark Access Check"), manual: true) { update in
            try self.withAccess([source, target]) {
                update(.init(fraction: 0.2, message: L("Reading Edge bookmarks…")))
                let edge = try EdgeFavorites(data: FavoritesEngine.read(source))
                update(.init(fraction: 0.6, message: L("Reading Safari bookmarks…")))
                let safari = try SafariFavorites(data: FavoritesEngine.read(target))
                return L("Edge: %1$@ bookmarks (%2$@ in the bookmarks bar). Safari: %3$@ bookmarks. Files are readable; no sync has been performed." , edge.count, edge.bar.reduce(0) { $0 + $1.count }, safari.count)
            }
        }
    }
    @objc private func syncNow(_ sender: Any?) { sync(manual: true) }
    private var selectedDirection: SyncDirection { SyncDirection(rawValue: direction.indexOfSelectedItem) ?? .edgeToSafari }
    private func isRunning(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
    private func sync(manual: Bool) {
        guard !busy else { return }
        let selectedDirection = self.selectedDirection
        let selectedMode = SyncMode(rawValue: mode.indexOfSelectedItem) ?? .incremental
        let needsQuit = selectedDirection.requiredApps.contains(where: isRunning)
        let targetName = selectedDirection == .edgeToSafari ? "Safari" : "Edge"
        if !manual && needsQuit {
            status.stringValue = L("Scheduled sync skipped: destination %1$@ is running. Quit it to allow the next scheduled run." , targetName)
            refreshQuickPanel()
            return
        }
        if manual && (needsQuit || selectedMode == .mirror) {
            let message = selectedMode == .mirror
                ? L("The source will replace all ordinary %1$@ bookmarks. Both files are backed up first, and the destination is asked to quit if needed. Cloud sync may propagate changes to other devices." , targetName)
                : L("Destination %1$@ will be asked to quit. Both files are then backed up before missing bookmarks are merged. Save any unsubmitted webpage content first." , targetName)
            guard confirm(selectedMode == .mirror ? L("Mirror to %1$@?" , targetName) : L("Destination %1$@ Needs to Quit" , targetName), message, action: selectedMode == .mirror ? L("Back Up and Mirror") : L("Quit Destination and Sync")) else { return }
        }
        let source = sourceURL, target = targetURL
        perform(title: L("Bookmark Sync"), manual: manual) { update in
            try self.withAccess([source, target]) {
                let edgeData = try FavoritesEngine.read(source), safariData = try FavoritesEngine.read(target)
                let edge = try EdgeFavorites(data: edgeData), safari = try SafariFavorites(data: safariData)
                if selectedDirection == .edgeToSafari {
                    guard edge.count > 0 else { throw SyncFailure.message(L("The Edge source is empty. No sync was performed.")) }
                } else {
                    guard safari.count > 0 else { throw SyncFailure.message(L("The Safari source is empty. No sync was performed.")) }
                    _ = try EdgeBookmarkDocument(data: edgeData)
                    _ = try safari.exported()
                }
                if manual { try self.quitBrowsers(selectedDirection.requiredApps, update: update) }
                return try self.dualEngine.sync(edgeURL: source, safariURL: target, direction: selectedDirection, mode: selectedMode, progress: update)
            }
        }
    }
    private var dualEngine: DualFavoritesEngine { DualFavoritesEngine(store: store, running: { self.isRunning($0) }) }
    private func quitBrowsers(_ ids: [String], update: (FavoritesProgress) -> Void) throws {
        guard ids.contains(where: isRunning) else { return }
        update(.init(fraction: 0.02, message: L("Waiting for the destination browser to quit. Complete any browser save prompts…")))
        let applications = ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        DispatchQueue.main.sync { applications.forEach { _ = $0.terminate() } }
        for _ in 0..<100 {
            if !ids.contains(where: isRunning) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw SyncFailure.message(L("The destination browser has not quit. No bookmarks were written. Quit it manually and try again."))
    }
    @objc private func backupNow(_ sender: Any?) {
        let source = sourceURL, target = targetURL
        perform(title: L("Manual Backup"), manual: true) { update in
            try self.withAccess([source, target]) {
                update(.init(fraction: 0.2, message: L("Reading both browsers’ saved bookmark files…")))
                let edgeData = try FavoritesEngine.read(source), safariData = try FavoritesEngine.read(target)
                update(.init(fraction: 0.55, message: L("Saving and verifying both original files…")))
                let backup = try self.store.save(safariData, edgeData: edgeData, edgePath: source.standardizedFileURL.path, reason: L("Manual backup of both browsers"))
                return L("Backed up Edge: %1$@ bookmarks; Safari: %2$@ bookmarks. Recent browser edits must first be saved to disk." , backup.edgeCount ?? 0, backup.count)
            }
        }
    }
    private var selectedBackups: [FavoritesBackup] { table.selectedRowIndexes.compactMap { backups.indices.contains($0) ? backups[$0] : nil } }
    @objc private func restoreSelected(_ sender: Any?) {
        guard !busy, selectedBackups.count == 1, let backup = selectedBackups.first else { return }
        let pair = backup.edgeSha256 != nil
        let scope = pair ? L("Edge and Safari") : L("Safari (legacy single-browser backup)")
        guard confirm(L("Restore the Selected Bookmark Backup?"), L("Restore the %2$@ bookmarks from %1$@. The destination browsers must quit. Both current files will be backed up first, and scheduled sync will be paused." , date(backup.createdAt), scope), action: L("Back Up and Restore")) else { return }
        automatic.state = .off; settingsChanged(nil)
        let source = sourceURL, target = targetURL
        perform(title: L("Bookmark Restore"), manual: true) { update in
            try self.withAccess([source, target]) {
                _ = try self.store.load(backup); _ = try self.store.loadEdge(backup)
                if pair, let path = backup.edgeProfilePath, path != source.standardizedFileURL.path { throw SyncFailure.message(L("First choose the Edge profile associated with this backup in Settings.")) }
                _ = try SafariFavorites(data: FavoritesEngine.read(target))
                _ = try EdgeFavorites(data: FavoritesEngine.read(source))
                try self.quitBrowsers(["com.apple.Safari"] + (pair ? ["com.microsoft.edgemac"] : []), update: update)
                return try self.dualEngine.restore(backup, edgeURL: source, safariURL: target, progress: update)
            }
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        let selected = selectedBackups
        guard !busy, !selected.isEmpty else { return }
        guard confirm(L("Delete %1$@ Bookmark Backups?" , selected.count), L("Selected backups will move to Trash and can be recovered until Trash is emptied. Browser bookmarks will not change."), action: L("Move to Trash")) else { return }
        perform(title: L("Backup Deletion"), manual: true) { update in
            for (index, backup) in selected.enumerated() {
                update(.init(fraction: Double(index) / Double(selected.count), message: L("Deleting backup %1$@ of %2$@…" , index + 1, selected.count)))
                try self.store.delete(backup)
            }
            return L("Moved %1$@ backups to Trash. Browser bookmarks were not changed." , selected.count)
        }
    }
    @objc private func previewSelected(_ sender: Any?) {
        guard selectedBackups.count == 1, let backup = selectedBackups.first else { return }
        do {
            var text = "SAFARI\n\n" + (try SafariFavorites(data: store.load(backup)).listing)
            if let edgeData = try store.loadEdge(backup) {
                let edge = try EdgeFavorites(data: edgeData)
                func listing(_ nodes: [BookmarkNode], depth: Int) -> String {
                    nodes.map { node in
                        let indent = String(repeating: "  ", count: depth)
                        if let url = node.url { return indent + node.title + "\n" + indent + url }
                        return indent + "▾ " + node.title + "\n" + listing(node.children, depth: depth + 1)
                    }.joined(separator: "\n")
                }
                text += L("\n\n────────────\nEDGE\n\nBookmarks Bar\n") + listing(edge.bar, depth: 1) + L("\nOther Bookmarks\n") + listing(edge.other, depth: 1)
            }
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = L("Backup Contents — %1$@" , date(backup.createdAt))
            panel.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: panel.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let view = NSTextView(frame: scroll.bounds); view.isEditable = false; view.isSelectable = true; view.string = text
            view.font = .systemFont(ofSize: 12); view.textContainerInset = NSSize(width: 16, height: 16); view.autoresizingMask = [.width]
            scroll.documentView = view; panel.contentView!.addSubview(scroll)
            window.addChildWindow(panel, ordered: .above); panel.center(); panel.makeKeyAndOrderFront(nil)
        } catch { showError(error) }
    }
    @objc private func openBackups(_ sender: Any?) {
        do { try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true); NSWorkspace.shared.open(store.directory) }
        catch { showError(error) }
    }
    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        quickPopover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func perform(title: String, manual: Bool, work: @escaping (@escaping (FavoritesProgress) -> Void) throws -> String) {
        guard !busy else { return }
        setBusy(true); progress.doubleValue = 0; status.textColor = .labelColor; status.stringValue = title + L(" is starting…")
        NSApp.dockTile.badgeLabel = "…"
        let update: (FavoritesProgress) -> Void = { value in DispatchQueue.main.async { self.updateProgress(value) } }
        queue.async {
            let result = Result { try work(update) }
            DispatchQueue.main.async {
                self.setBusy(false); self.reloadBackups()
                switch result {
                case .success(let message):
                    self.progress.doubleValue = 100; self.status.textColor = .systemGreen
                    self.status.stringValue = "✓ \(self.date(Date())) · \(message)"; NSApp.dockTile.badgeLabel = "✓"
                    self.writeLog(title + L(" completed: ") + message)
                    if manual { self.showCompletion(title + L(" Complete"), message) }
                case .failure(let error):
                    self.status.textColor = .systemRed; self.status.stringValue = L("Operation incomplete: ") + error.localizedDescription
                    NSApp.dockTile.badgeLabel = "!"; self.writeLog(title + L(" failed: ") + error.localizedDescription)
                    if manual { self.showError(error) }
                }
                self.refreshQuickPanel()
                if self.terminationPending { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
    }
    private func updateProgress(_ value: FavoritesProgress) {
        progress.isIndeterminate = value.fraction <= 0.03
        if progress.isIndeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.doubleValue = value.fraction * 100
        status.stringValue = value.message
        refreshQuickPanel()
    }
    private func setBusy(_ value: Bool) {
        busy = value
        for control in [direction, syncButton, backupButton, deleteButton, restoreButton, previewButton, authorizeButton, sourceButton, checkButton, mode, profile, automatic, minutes, language] as [NSControl] { control.isEnabled = !value }
        progress.isHidden = !value
        if value { progress.isIndeterminate = true; progress.startAnimation(nil) }
        else { progress.stopAnimation(nil); updateSelectionButtons(); minutes.isEnabled = automatic.state == .on }
        refreshQuickPanel()
    }

    private func reloadBackups() {
        do { backups = try store.list() } catch { status.stringValue = L("Could not read the backup list: ") + error.localizedDescription }
        table.reloadData()
        emptyBackups.stringValue = backups.isEmpty ? L("No backups yet. Click Back Up Both Now, or create the first backup automatically during sync.") : L("%1$@ backups. Numbers show each browser’s ordinary bookmark count." , backups.count)
        if !backups.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateSelectionButtons()
    }
    private func updateSelectionButtons() {
        restoreButton.isEnabled = !busy && selectedBackups.count == 1
        previewButton.isEnabled = !busy && selectedBackups.count == 1
        deleteButton.isEnabled = !busy && !selectedBackups.isEmpty
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelectionButtons() }
    private func showError(_ error: Error) {
        if let access = error as? FavoritesAccessError {
            let alert = makePermissionAlert(access)
            presentAlert(alert) { response in
                if response == .alertFirstButtonReturn { self.openPermissions(nil) }
                else if response == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    self.status.stringValue = L("The current app is selected in Finder. Add it to Full Disk Access, enable it, then reopen the app.")
                }
            }
            return
        }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = L("Operation Incomplete"); alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK")); presentAlert(alert)
    }
    private func makePermissionAlert(_ error: FavoritesAccessError) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Bookmark Access Required")
        alert.informativeText = error.localizedDescription + L("\n\n1. Click below to open the relevant settings.\n2. Click +, add the current app, and enable it.\n3. Reopen this app when prompted, then click Check Access.\n\nCurrent app:\n") + Bundle.main.bundleURL.path
        alert.addButton(withTitle: L("Open Full Disk Access Settings"))
        alert.addButton(withTitle: L("Show This App in Finder"))
        alert.addButton(withTitle: L("Later"))
        return alert
    }
    private func showCompletion(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = "✓ " + title; alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        let targetID = title == L("Bookmark Sync Complete") && selectedDirection == .safariToEdge ? "com.microsoft.edgemac" : "com.apple.Safari"
        if title == L("Bookmark Sync Complete") || title == L("Bookmark Restore Complete") { alert.addButton(withTitle: targetID == "com.apple.Safari" ? L("Open Safari") : L("Open Edge")) }
        presentAlert(alert) { response in
            if response == .alertSecondButtonReturn, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
    }
    private func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        if window.isVisible { alert.beginSheetModal(for: window, completionHandler: completion) }
        else {
            quickPopover.performClose(nil)
            NSApp.activate(ignoringOtherApps: true)
            completion(alert.runModal())
        }
    }
    private func writeLog(_ message: String) {
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let url = support.appendingPathComponent("FavoritesSync.log")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data((date(Date()) + " " + message + "\n").utf8))
        } catch { /* Status and dialog still report the operation result. */ }
    }
    private func date(_ value: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: value) }
    func numberOfRows(in tableView: NSTableView) -> Int { backups.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let backup = backups[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = date(backup.createdAt)
        case "safari": text = String(backup.count)
        case "edge": text = backup.edgeCount.map(String.init) ?? "—"
        default: text = backup.reason
        }
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingTail; field.toolTip = text; return field
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
if ProcessInfo.processInfo.arguments.contains("--ui-smoke-test") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        FileHandle.standardError.write(Data("FAIL: UI startup did not complete within 10 seconds.\n".utf8)); exit(2)
    }
}
withExtendedLifetime(delegate) { application.run() }

import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var historyWindowController: HistoryWindowController?
    private var statusItem: NSStatusItem!
    private var theMenu: NSMenu!
    private var localKeystrokeCount: Int = 0
    private var localAppCounts: [String: Int] = [:]  // bundleID -> count for today
    private var totalKeystrokeCount: Int = 0
    private var localExtras = DayExtras()  // dictation + WPM metrics for today on this device
    private var lastTypingKeyTime: Date?
    private var unsavedCount = 0
    private var unsyncedCount = 0
    private let micTracker = MicSessionTracker()
    /// Gaps between keystrokes longer than this end a typing burst (not counted as typing time).
    private let typingIdleThreshold: TimeInterval = 2.0
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hasAccessibilityPermission = false
    private var permissionCheckTimer: Timer?
    private var syncTimer: Timer?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var lastSyncTime: Date?
    // in-memory cache; disk syncs happen async
    private var cachedSyncData = SyncData()
    private var updateChecker = UpdateChecker.shared
    private var updateDotLayer: CALayer?

    private let deviceID: String = {
        let defaults = UserDefaults.standard
        let key = "deviceUUID"
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: key)
        return newID
    }()

    private var syncFileURL: URL? {
        let fileManager = FileManager.default
        if let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            let docsURL = iCloudURL.appendingPathComponent("Documents")
            try? fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
            return docsURL.appendingPathComponent("typing-stats.json")
        }
        let cloudDocsPath = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        if fileManager.fileExists(atPath: cloudDocsPath) {
            let appFolder = URL(fileURLWithPath: cloudDocsPath).appendingPathComponent("TypingStats")
            try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
            return appFolder.appendingPathComponent("typing-stats.json")
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("TypingStats")
        try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("typing-stats.json")
    }

    private let localDefaultsKey = "localKeystrokeData"
    private let syncQueue = DispatchQueue(label: "com.typing-stats.sync", qos: .utility)
    private let fileCoordinator = NSFileCoordinator()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        loadLocalCount()
        loadAndReconcileCounts()

        hasAccessibilityPermission = AXIsProcessTrusted()
        setupMenuBar()

        if hasAccessibilityPermission {
            startMonitoring()
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            startPermissionCheckTimer()
        }

        micTracker.start()
        startSyncTimer()
        startFileMonitor()
        _ = updateChecker // Initialize Sparkle

        // Listen for update availability
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdateAvailable),
            name: UpdateChecker.updateAvailableNotification,
            object: nil
        )

        checkFirstRun()
    }

    /// Hidden main menu (accessory apps don't show it) so standard shortcuts work in our windows:
    /// Cmd+W close, Cmd+Q quit, Cmd+M minimize, and Edit shortcuts.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleUpdateAvailable() {
        setStatusItemUpdateBadgeVisible(true)
        rebuildMenu()
    }

    private func checkFirstRun() {
        let defaults = UserDefaults.standard
        let hasSetupLoginItem = defaults.bool(forKey: "hasSetupLoginItem")

        if !hasSetupLoginItem {
            defaults.set(true, forKey: "hasSetupLoginItem")
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("Failed to enable launch at login: \(error)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        fileMonitor?.cancel()
        syncTimer?.invalidate()
        permissionCheckTimer?.invalidate()

        checkDayChange()
        saveLocalCount()

        guard let url = syncFileURL else { return }
        let today = todayString()
        let finalCount = localKeystrokeCount

        let finalAppCounts = localAppCounts
        let finalExtras = localExtras
        coordinatedSync(to: url) { existingData in
            var syncData = existingData
            if syncData.devices[self.deviceID] == nil {
                syncData.devices[self.deviceID] = DeviceData()
            }
            let existing = syncData.devices[self.deviceID]?.dailyCounts[today]
            let existingCount = existing?.count ?? 0
            if finalCount > existingCount {
                syncData.devices[self.deviceID]?.setCount(finalCount, for: today, appCounts: finalAppCounts.isEmpty ? nil : finalAppCounts, extras: finalExtras)
            } else if finalCount == existingCount, let existing = existing {
                // Typing time can grow without the count changing (e.g. after a pause); keep the max.
                syncData.devices[self.deviceID]?.dailyCounts[today]?.extras = existing.extras.merged(with: finalExtras)
            }
            return syncData
        }
    }

    // MARK: - Local Storage

    private func loadLocalCount() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: localDefaultsKey),
           let state = try? JSONDecoder().decode(LocalState.self, from: data) {
            if state.date == todayString() {
                localKeystrokeCount = state.count
                localAppCounts = state.appCounts ?? [:]
                localExtras = state.extras ?? DayExtras()
            } else {
                localKeystrokeCount = 0
                localAppCounts = [:]
                localExtras = DayExtras()
            }
        }
    }

    private func saveLocalCount() {
        unsavedCount = 0
        let state = LocalState(date: todayString(), count: localKeystrokeCount, appCounts: localAppCounts.isEmpty ? nil : localAppCounts, extras: localExtras.isEmpty ? nil : localExtras)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: localDefaultsKey)
        }
    }

    // MARK: - Sync Storage

    private func loadAndReconcileCounts() {
        guard let url = syncFileURL else {
            totalKeystrokeCount = localKeystrokeCount
            saveLocalCount()
            return
        }

        coordinatedSync(to: url) { syncData in
            var updated = syncData
            let today = self.todayString()

            if updated.devices[self.deviceID] == nil {
                updated.devices[self.deviceID] = DeviceData()
            }

            let existingCount = updated.devices[self.deviceID]?.count(for: today) ?? 0

            if self.localKeystrokeCount == 0 {
                // Fresh start for today - reset cloud to 0, don't pull corrupted data
                updated.devices[self.deviceID]?.setCount(0, for: today, appCounts: nil)
            } else if self.localKeystrokeCount > existingCount {
                updated.devices[self.deviceID]?.setCount(self.localKeystrokeCount, for: today, appCounts: self.localAppCounts.isEmpty ? nil : self.localAppCounts, extras: self.localExtras)
            } else {
                self.localKeystrokeCount = existingCount
                // Also load app counts from cloud if available
                let cloudAppCounts = updated.devices[self.deviceID]?.appCounts(for: today) ?? [:]
                if !cloudAppCounts.isEmpty {
                    self.localAppCounts = cloudAppCounts
                }
                let cloudExtras = updated.devices[self.deviceID]?.extras(for: today) ?? DayExtras()
                self.localExtras = self.localExtras.merged(with: cloudExtras)
            }

            updated.pruneAllDevices(keepingDays: 60)
            self.cachedSyncData = updated
            self.totalKeystrokeCount = updated.totalCount(for: today)
            self.saveLocalCount()
            return updated
        }
    }

    private func coordinatedSync(to url: URL, forceMerge: Bool = true, transform: @escaping (SyncData) -> SyncData) {
        var coordinatorError: NSError?
        var readData = SyncData()

        fileCoordinator.coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinatorError
        ) { coordURL in
            if FileManager.default.fileExists(atPath: coordURL.path),
               let data = try? Data(contentsOf: coordURL),
               let existing = try? JSONDecoder().decode(SyncData.self, from: data) {
                readData = existing
            }

            var newData = transform(readData)

            if forceMerge,
               FileManager.default.fileExists(atPath: coordURL.path),
               let freshData = try? Data(contentsOf: coordURL),
               let freshSync = try? JSONDecoder().decode(SyncData.self, from: freshData) {
                newData.merge(with: freshSync)
            }

            if let encoded = try? JSONEncoder().encode(newData) {
                try? encoded.write(to: coordURL, options: .atomic)
            }
        }

        if let error = coordinatorError {
            print("File coordination error: \(error)")
        }
    }

    private func loadSyncData(from url: URL) -> SyncData {
        var result = SyncData()
        var coordinatorError: NSError?

        fileCoordinator.coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinatorError
        ) { coordURL in
            guard FileManager.default.fileExists(atPath: coordURL.path),
                  let data = try? Data(contentsOf: coordURL),
                  let syncData = try? JSONDecoder().decode(SyncData.self, from: data) else {
                return
            }
            result = syncData
        }

        return result
    }

    private func syncToCloud() {
        guard let url = syncFileURL else { return }

        checkDayChange()

        let today = todayString()
        let currentLocalCount = localKeystrokeCount
        let currentAppCounts = localAppCounts
        let currentExtras = localExtras
        unsyncedCount = 0

        syncQueue.async { [weak self] in
            guard let self = self else { return }

            self.coordinatedSync(to: url) { existingData in
                var syncData = existingData

                if syncData.devices[self.deviceID] == nil {
                    syncData.devices[self.deviceID] = DeviceData()
                }

                let existing = syncData.devices[self.deviceID]?.dailyCounts[today]
                let existingCount = existing?.count ?? 0

                if currentLocalCount > existingCount {
                    syncData.devices[self.deviceID]?.setCount(currentLocalCount, for: today, appCounts: currentAppCounts.isEmpty ? nil : currentAppCounts, extras: currentExtras)
                } else if currentLocalCount == existingCount, let existing = existing {
                    syncData.devices[self.deviceID]?.dailyCounts[today]?.extras = existing.extras.merged(with: currentExtras)
                }

                return syncData
            }

            let syncData = self.loadSyncData(from: url)

            DispatchQueue.main.async {
                self.cachedSyncData = syncData
                // Re-apply local count — may have advanced while sync was in flight
                if self.cachedSyncData.devices[self.deviceID] == nil {
                    self.cachedSyncData.devices[self.deviceID] = DeviceData()
                }
                self.cachedSyncData.devices[self.deviceID]?.setCount(self.localKeystrokeCount, for: today, appCounts: self.localAppCounts.isEmpty ? nil : self.localAppCounts, extras: self.localExtras)
                self.lastSyncTime = Date()

                let reconciledTotal = self.cachedSyncData.totalCount(for: today)
                if reconciledTotal != self.totalKeystrokeCount {
                    self.totalKeystrokeCount = reconciledTotal
                    self.updateMenuBarTitle()
                }
            }
        }
    }

    // MARK: - File Monitoring

    private func startFileMonitor() {
        guard let url = syncFileURL else { return }

        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            coordinatedSync(to: url) { _ in SyncData() }
        }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )

        fileMonitor?.setEventHandler { [weak self] in
            self?.handleFileChange()
        }

        fileMonitor?.setCancelHandler {
            close(fd)
        }

        fileMonitor?.resume()
    }

    private func handleFileChange() {
        guard let url = syncFileURL else { return }

        checkDayChange()

        let today = todayString()

        syncQueue.async { [weak self] in
            guard let self = self else { return }

            let syncData = self.loadSyncData(from: url)

            if let cloudDeviceData = syncData.devices[self.deviceID] {
                let cloudCount = cloudDeviceData.count(for: today)
                if cloudCount > self.localKeystrokeCount {
                    let cloudExtras = cloudDeviceData.extras(for: today)
                    DispatchQueue.main.async {
                        self.localKeystrokeCount = cloudCount
                        self.localExtras = self.localExtras.merged(with: cloudExtras)
                        self.saveLocalCount()
                    }
                }
            }

            DispatchQueue.main.async {
                self.cachedSyncData = syncData
                // Re-apply local count — may have advanced while reading file
                if self.cachedSyncData.devices[self.deviceID] == nil {
                    self.cachedSyncData.devices[self.deviceID] = DeviceData()
                }
                self.cachedSyncData.devices[self.deviceID]?.setCount(self.localKeystrokeCount, for: today, appCounts: self.localAppCounts.isEmpty ? nil : self.localAppCounts, extras: self.localExtras)

                let reconciledTotal = self.cachedSyncData.totalCount(for: today)
                if reconciledTotal != self.totalKeystrokeCount {
                    self.totalKeystrokeCount = reconciledTotal
                    self.updateMenuBarTitle()
                }
            }
        }
    }

    // MARK: - Timers

    private func startSyncTimer() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.syncToCloud()
        }
    }

    private func startPermissionCheckTimer() {
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let nowHasPermission = AXIsProcessTrusted()
            if nowHasPermission && !self.hasAccessibilityPermission {
                self.hasAccessibilityPermission = true
                self.permissionCheckTimer?.invalidate()
                self.permissionCheckTimer = nil
                self.startMonitoring()
                self.rebuildMenu()
                self.updateMenuBarTitle()
            }
        }
    }

    // MARK: - Helpers

    private func checkDayChange() {
        let today = todayString()
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: localDefaultsKey),
           let state = try? JSONDecoder().decode(LocalState.self, from: data),
           state.date != today {
            localKeystrokeCount = 0
            localAppCounts = [:]
            localExtras = DayExtras()
            lastTypingKeyTime = nil
            totalKeystrokeCount = 0
            loadAndReconcileCounts()
        }
    }

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func yesterdayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        return formatter.string(from: yesterday)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return String(format: "%.2fM", m)
        } else if count >= 1000 {
            let k = Double(count) / 1000.0
            return String(format: "%.2fk", k)
        }
        return "\(count)"
    }

    private func formatCountFull(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func getStats() -> (today: Int, yesterday: Int, avg7: Double, avg30: Double, recordCount: Int, recordDate: String?) {
        let today = todayString()
        let yesterday = yesterdayString()

        let todayCount = cachedSyncData.totalCount(for: today)
        let yesterdayCount = cachedSyncData.totalCount(for: yesterday)
        let avg7 = cachedSyncData.averageCount(forLastDays: 7, from: Date())
        let avg30 = cachedSyncData.averageCount(forLastDays: 30, from: Date())
        let record = cachedSyncData.recordDay()

        return (todayCount, yesterdayCount, avg7, avg30, record?.count ?? 0, record?.date)
    }

    private func formatDateShort(_ dateString: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"

        guard let date = inputFormatter.date(from: dateString) else {
            return dateString
        }

        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MM/dd"
        return outputFormatter.string(from: date)
    }

    // MARK: - Menu Bar Icons

    private func createKeyboardIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let scale: CGFloat = 18.0 / 24.0
            let lineWidth: CGFloat = 1.5

            // Use yellow for dev builds, black for release
            let color = isDevBuild ? NSColor.systemYellow : NSColor.black
            color.setStroke()

            let bodyRect = NSRect(x: 3 * scale, y: 6 * scale, width: 18 * scale, height: 12 * scale)
            let body = NSBezierPath(roundedRect: bodyRect, xRadius: 2 * scale, yRadius: 2 * scale)
            body.lineWidth = lineWidth
            body.stroke()

            let spacebar = NSBezierPath()
            spacebar.move(to: NSPoint(x: 10 * scale, y: 14 * scale))
            spacebar.line(to: NSPoint(x: 14 * scale, y: 14 * scale))
            spacebar.lineWidth = lineWidth
            spacebar.lineCapStyle = .round
            spacebar.stroke()

            let dotRadius: CGFloat = 0.8
            let dots: [(CGFloat, CGFloat)] = [
                (6.5, 10), (6.5, 14),
                (10, 10),
                (14, 10),
                (17.5, 10), (17.5, 14)
            ]

            for (x, y) in dots {
                let dotRect = NSRect(
                    x: x * scale - dotRadius,
                    y: y * scale - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
                let dot = NSBezierPath(ovalIn: dotRect)
                color.setFill()
                dot.fill()
            }

            return true
        }

        // Only use template mode for release builds (so they adapt to dark mode)
        // Dev builds use explicit yellow color
        image.isTemplate = !isDevBuild
        return image
    }

    private func createWarningIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let str = "\u{26A0}\u{FE0E}"
            let font = NSFont.systemFont(ofSize: 14)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let attrStr = NSAttributedString(string: str, attributes: attrs)
            let strSize = attrStr.size()
            let point = NSPoint(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2
            )
            attrStr.draw(at: point)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        theMenu = NSMenu()
        theMenu.delegate = self
        statusItem.menu = theMenu
        updateMenuBarTitle()
        rebuildMenu()
    }

    private func rebuildMenu() {
        theMenu.removeAllItems()

        // Update blue dot visibility based on update availability
        setStatusItemUpdateBadgeVisible(updateChecker.updateAvailable)

        if !hasAccessibilityPermission {
            let permissionItem = NSMenuItem(
                title: "\u{26A0}\u{FE0E} Grant Accessibility Permission",
                action: #selector(requestAccessibilityPermission),
                keyEquivalent: ""
            )
            theMenu.addItem(permissionItem)
            theMenu.addItem(NSMenuItem.separator())
        }

        let stats = getStats()

        let todayItem = NSMenuItem(title: "Today: \(formatCountFull(stats.today))", action: nil, keyEquivalent: "")
        todayItem.isEnabled = false
        theMenu.addItem(todayItem)

        let todayExtras = cachedSyncData.totalExtras(for: todayString())
        if todayExtras.dictatedCount > 0 {
            let typed = max(0, stats.today - todayExtras.dictatedCount)
            let splitItem = NSMenuItem(
                title: "    Typed \(formatCountFull(typed)) · Dictated \(formatCountFull(todayExtras.dictatedCount))",
                action: nil, keyEquivalent: "")
            splitItem.isEnabled = false
            theMenu.addItem(splitItem)
        }
        let todayWPM = cachedSyncData.wpm(forDays: 1, from: Date())
        let weekWPM = cachedSyncData.wpm(forDays: 7, from: Date())
        func wpmPart(_ name: String, today: Double?, week: Double?) -> String? {
            if let v = today { return "\(name) \(Int(v.rounded())) WPM" }
            if let v = week { return "\(name) \(Int(v.rounded())) WPM (7d)" }
            return nil
        }
        let wpmParts = [
            wpmPart("Typing", today: todayWPM.typing, week: weekWPM.typing),
            wpmPart("Speaking", today: todayWPM.speaking, week: weekWPM.speaking),
        ].compactMap { $0 }
        if !wpmParts.isEmpty {
            let wpmItem = NSMenuItem(title: "Speed: " + wpmParts.joined(separator: " · "), action: nil, keyEquivalent: "")
            wpmItem.isEnabled = false
            theMenu.addItem(wpmItem)
        }

        let yesterdayItem = NSMenuItem(title: "Yesterday: \(formatCountFull(stats.yesterday))", action: nil, keyEquivalent: "")
        yesterdayItem.isEnabled = false
        theMenu.addItem(yesterdayItem)

        let avg7Item = NSMenuItem(title: "7-day avg: \(formatCountFull(Int(stats.avg7)))", action: nil, keyEquivalent: "")
        avg7Item.isEnabled = false
        theMenu.addItem(avg7Item)

        let avg30Item = NSMenuItem(title: "30-day avg: \(formatCountFull(Int(stats.avg30)))", action: nil, keyEquivalent: "")
        avg30Item.isEnabled = false
        theMenu.addItem(avg30Item)

        if let recordDate = stats.recordDate {
            let recordItem = NSMenuItem(title: "Record: \(formatCountFull(stats.recordCount)) (\(formatDateShort(recordDate)))", action: nil, keyEquivalent: "")
            recordItem.isEnabled = false
            theMenu.addItem(recordItem)
        }

        theMenu.addItem(NSMenuItem.separator())

        theMenu.addItem(NSMenuItem(
            title: "View History...",
            action: #selector(openHistory),
            keyEquivalent: ""
        ))

        theMenu.addItem(NSMenuItem.separator())

        let launchAtLogin = SMAppService.mainApp.status == .enabled
        let loginItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.state = launchAtLogin ? .on : .off
        theMenu.addItem(loginItem)

        theMenu.addItem(NSMenuItem.separator())

        if let version = updateChecker.availableVersion, updateChecker.isReadyToInstall {
            // Already downloaded: one click installs and relaunches, no Sparkle dialog.
            theMenu.addItem(NSMenuItem(
                title: "Restart to Update (v\(version))",
                action: #selector(installUpdateNow),
                keyEquivalent: ""
            ))
        } else if let version = updateChecker.availableVersion {
            theMenu.addItem(NSMenuItem(
                title: "Install Update (v\(version))...",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            ))
        } else {
            theMenu.addItem(NSMenuItem(
                title: "Check for Updates...",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            ))
        }

        theMenu.addItem(NSMenuItem(
            title: "About Typing Stats",
            action: #selector(showAbout),
            keyEquivalent: ""
        ))

        theMenu.addItem(NSMenuItem.separator())

        theMenu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        if NSEvent.modifierFlags.contains(.option) {
            theMenu.addItem(NSMenuItem.separator())

            let debugHeader = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
            debugHeader.isEnabled = false
            theMenu.addItem(debugHeader)

            let lastSyncString: String
            if let lastSync = lastSyncTime {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                lastSyncString = formatter.string(from: lastSync)
            } else {
                lastSyncString = "Never"
            }
            let syncItem = NSMenuItem(title: "Last sync: \(lastSyncString)", action: nil, keyEquivalent: "")
            syncItem.isEnabled = false
            theMenu.addItem(syncItem)

            let deviceItem = NSMenuItem(title: "Device: \(String(deviceID.prefix(8)))...", action: nil, keyEquivalent: "")
            deviceItem.isEnabled = false
            theMenu.addItem(deviceItem)

            theMenu.addItem(NSMenuItem(
                title: "Reset Today",
                action: #selector(resetToday),
                keyEquivalent: ""
            ))
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkDayChange()
        rebuildMenu()
        // Clicking the status item surfaces any open History/About windows behind the menu.
        for window in [historyWindowController?.window, aboutWindowController?.window].compactMap({ $0 })
            where window.isVisible && !window.isMiniaturized {
            window.orderFrontRegardless()
        }
    }

    private func updateMenuBarTitle() {
        let title = formatCount(totalKeystrokeCount)

        DispatchQueue.main.async {
            guard let button = self.statusItem?.button else { return }

            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            button.attributedTitle = NSAttributedString(string: " " + title, attributes: attributes)

            button.image = self.hasAccessibilityPermission
                ? self.createKeyboardIcon()
                : self.createWarningIcon()
        }
    }

    private func setStatusItemUpdateBadgeVisible(_ visible: Bool) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        if updateDotLayer == nil {
            let diameter: CGFloat = 6
            let layer = CALayer()
            layer.backgroundColor = NSColor.systemBlue.cgColor
            layer.cornerRadius = diameter / 2
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.cgColor
            // Position near top-right with a small inset
            layer.frame = CGRect(
                x: button.bounds.width - diameter - 2,
                y: button.bounds.height - diameter - 2,
                width: diameter,
                height: diameter
            )
            layer.autoresizingMask = [.layerMinXMargin, .layerMinYMargin]
            button.layer?.addSublayer(layer)
            updateDotLayer = layer
        }
        updateDotLayer?.isHidden = !visible
    }

    // MARK: - Menu Actions

    @objc private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func openHistory() {
        guard let url = syncFileURL else { return }

        checkDayChange()

        // Reuse the open window instead of stacking a new one per click.
        if let existing = historyWindowController?.window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        historyWindowController = HistoryWindowController(syncData: cachedSyncData, dataFileURL: url) { [weak self] in
            self?.cachedSyncData ?? SyncData()
        }
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func resetToday() {
        let alert = NSAlert()
        alert.messageText = "Reset Today's Count?"
        alert.informativeText = "This will reset your keystroke count to 0 for today on this device. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            localKeystrokeCount = 0
            localAppCounts = [:]
            localExtras = DayExtras()
            lastTypingKeyTime = nil
            saveLocalCount()

            let today = todayString()

            if cachedSyncData.devices[deviceID] == nil {
                cachedSyncData.devices[deviceID] = DeviceData()
            }
            cachedSyncData.devices[deviceID]?.setCount(0, for: today, appCounts: nil)
            totalKeystrokeCount = cachedSyncData.totalCount(for: today)
            updateMenuBarTitle()

            // Write reset to iCloud file async
            if let url = syncFileURL {
                syncQueue.async {
                    self.coordinatedSync(to: url, forceMerge: false) { existingData in
                        var syncData = existingData
                        if syncData.devices[self.deviceID] == nil {
                            syncData.devices[self.deviceID] = DeviceData()
                        }
                        syncData.devices[self.deviceID]?.setCount(0, for: today, appCounts: nil)
                        return syncData
                    }
                }
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private var aboutWindowController: AboutWindowController?

    @objc private func showAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController(updateChecker: updateChecker)
        }
        aboutWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func installUpdateNow() {
        // Persist today's counts before Sparkle terminates and relaunches the app.
        saveLocalCount()
        updateChecker.installUpdate()
    }

    @objc private func checkForUpdates() {
        updateChecker.checkForUpdates()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Keystroke Monitoring

    private func startMonitoring() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                if let refcon = refcon {
                    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        // macOS disables slow taps; turn it back on instead of silently stopping.
                        if let tap = appDelegate.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else if type == .keyDown {
                        appDelegate.handleKeyEvent(event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handleKeyEvent(_ event: CGEvent) {
        checkDayChange()

        // Track which app received this keystroke
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"

        // Real key presses report source PID 0; synthetic events carry the poster's PID.
        let sourcePID = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        let isSynthetic = sourcePID != 0 && sourcePID != getpid()
        let dictationApp = isSynthetic ? DictationSources.dictationApp(forPID: sourcePID) : nil

        let added: Int
        if let dictationApp = dictationApp {
            guard isPasteShortcut(event), let chars = dictatedCharacters() else {
                // Other synthetic keys from a dictation app (auto-Enter, Backspace…) aren't typing.
                return
            }
            added = chars
            localExtras.dictatedCount = localExtras.dictatedCount.saturatingAdd(chars)
            localExtras.dictatedAppCounts[bundleID] = (localExtras.dictatedAppCounts[bundleID] ?? 0).saturatingAdd(chars)
            if let seconds = micTracker.claimSession(for: dictationApp) {
                localExtras.speakingSeconds += seconds
                localExtras.speakingChars = localExtras.speakingChars.saturatingAdd(chars)
            }
        } else {
            added = 1
            if !isSynthetic {
                recordTypingTiming()
            }
        }

        localAppCounts[bundleID, default: 0] += added
        localKeystrokeCount += added
        totalKeystrokeCount += added

        // Keep cache current so menu reads never hit disk
        if cachedSyncData.devices[deviceID] == nil {
            cachedSyncData.devices[deviceID] = DeviceData()
        }
        cachedSyncData.devices[deviceID]?.setCount(localKeystrokeCount, for: todayString(), appCounts: localAppCounts.isEmpty ? nil : localAppCounts, extras: localExtras)

        updateMenuBarTitle()

        // Thresholds are cumulative because dictation adds many characters at once.
        unsavedCount += added
        unsyncedCount += added
        if unsavedCount >= 50 {
            saveLocalCount()
        }

        // Flush to iCloud file in background
        if unsyncedCount >= 1000 {
            syncToCloud()
        }
    }

    // MARK: - Dictation & WPM

    private func isPasteShortcut(_ event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        return keycode == 9 /* kVK_ANSI_V */ && event.flags.contains(.maskCommand)
    }

    /// Length of the transcript on the clipboard. Read synchronously inside the tap, before
    /// the target app handles the paste and before the dictation app restores the clipboard.
    /// Only the length is used; the text is never stored, logged, or synced.
    /// Runs only for synthetic Cmd+V from an allowlisted dictation app, so password-manager
    /// pastes aren't sampled. Concealed/transient markers can't be used as a filter because
    /// dictation apps (e.g. Aqua) set them on their own transcripts.
    private func dictatedCharacters() -> Int? {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        // Universal Clipboard content would need a network fetch; dictation apps write locally.
        guard types.contains(.string),
              !types.contains(NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")),
              let text = pasteboard.string(forType: .string) else { return nil }
        // NSString length (UTF-16 units) is O(1), so long pastes can't stall the event tap.
        let length = (text as NSString).length
        return length > 0 ? length : nil
    }

    /// Accumulate active typing time from gaps between hardware keystrokes.
    private func recordTypingTiming() {
        let now = Date()
        if let last = lastTypingKeyTime {
            let gap = now.timeIntervalSince(last)
            if gap >= 0 && gap <= typingIdleThreshold {
                localExtras.typingSeconds += gap
                localExtras.typingKeys = localExtras.typingKeys.saturatingAdd(1)
            }
        }
        lastTypingKeyTime = now
    }
}

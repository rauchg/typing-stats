import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var historyWindowController: HistoryWindowController?
    private var statusItem: NSStatusItem!
    private var theMenu: NSMenu!
    private var localKeystrokeCount: Int = 0
    private var totalKeystrokeCount: Int = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hasAccessibilityPermission = false
    private var permissionCheckTimer: Timer?
    private var syncTimer: Timer?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var lastSyncTime: Date?
    private var updateChecker = UpdateChecker.shared

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

        startSyncTimer()
        startFileMonitor()
        _ = updateChecker // Initialize Sparkle

        checkFirstRun()
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

        coordinatedSync(to: url) { existingData in
            var syncData = existingData
            if syncData.devices[self.deviceID] == nil {
                syncData.devices[self.deviceID] = DeviceData()
            }
            let existingCount = syncData.devices[self.deviceID]?.count(for: today) ?? 0
            if finalCount > existingCount {
                syncData.devices[self.deviceID]?.setCount(finalCount, for: today)
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
            } else {
                localKeystrokeCount = 0
            }
        }
    }

    private func saveLocalCount() {
        let state = LocalState(date: todayString(), count: localKeystrokeCount)
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
                updated.devices[self.deviceID]?.setCount(0, for: today)
            } else if self.localKeystrokeCount > existingCount {
                updated.devices[self.deviceID]?.setCount(self.localKeystrokeCount, for: today)
            } else {
                self.localKeystrokeCount = existingCount
            }

            updated.pruneAllDevices(keepingDays: 60)
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

        syncQueue.async { [weak self] in
            guard let self = self else { return }

            self.coordinatedSync(to: url) { existingData in
                var syncData = existingData

                if syncData.devices[self.deviceID] == nil {
                    syncData.devices[self.deviceID] = DeviceData()
                }

                let existingCount = syncData.devices[self.deviceID]?.count(for: today) ?? 0

                if currentLocalCount > existingCount {
                    syncData.devices[self.deviceID]?.setCount(currentLocalCount, for: today)
                }

                return syncData
            }

            let syncData = self.loadSyncData(from: url)
            let newTotal = syncData.totalCount(for: today)

            DispatchQueue.main.async {
                self.lastSyncTime = Date()

                if newTotal != self.totalKeystrokeCount {
                    self.totalKeystrokeCount = newTotal
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
                    DispatchQueue.main.async {
                        self.localKeystrokeCount = cloudCount
                        self.saveLocalCount()
                    }
                }
            }

            let newTotal = syncData.totalCount(for: today)

            if newTotal != self.totalKeystrokeCount {
                DispatchQueue.main.async {
                    self.totalKeystrokeCount = newTotal
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
        guard let url = syncFileURL else {
            return (totalKeystrokeCount, 0, 0, 0, totalKeystrokeCount, nil)
        }

        let syncData = loadSyncData(from: url)
        let today = todayString()
        let yesterday = yesterdayString()

        let todayCount = syncData.totalCount(for: today)
        let yesterdayCount = syncData.totalCount(for: yesterday)
        let avg7 = syncData.averageCount(forLastDays: 7, from: Date())
        let avg30 = syncData.averageCount(forLastDays: 30, from: Date())

        let record = syncData.recordDay()

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

            NSColor.black.setStroke()

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
                NSColor.black.setFill()
                dot.fill()
            }

            return true
        }

        image.isTemplate = true
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

        theMenu.addItem(NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        ))

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
        // Sync local data to cloud before showing menu (like openHistory does)
        if let url = syncFileURL {
            checkDayChange()
            saveLocalCount()
            let today = todayString()
            let currentCount = localKeystrokeCount
            coordinatedSync(to: url, forceMerge: false) { existingData in
                var syncData = existingData
                if syncData.devices[self.deviceID] == nil {
                    syncData.devices[self.deviceID] = DeviceData()
                }
                let existingCount = syncData.devices[self.deviceID]?.count(for: today) ?? 0
                if currentCount > existingCount {
                    syncData.devices[self.deviceID]?.setCount(currentCount, for: today)
                }
                return syncData
            }
        }
        rebuildMenu()
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

    // MARK: - Menu Actions

    @objc private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func openHistory() {
        guard let url = syncFileURL else { return }

        checkDayChange()
        saveLocalCount()
        let today = todayString()
        let currentCount = localKeystrokeCount
        coordinatedSync(to: url, forceMerge: false) { existingData in
            var syncData = existingData
            if syncData.devices[self.deviceID] == nil {
                syncData.devices[self.deviceID] = DeviceData()
            }
            let existingCount = syncData.devices[self.deviceID]?.count(for: today) ?? 0
            if currentCount > existingCount {
                syncData.devices[self.deviceID]?.setCount(currentCount, for: today)
            }
            return syncData
        }

        let syncData = loadSyncData(from: url)

        historyWindowController = HistoryWindowController(syncData: syncData, dataFileURL: url)
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
            saveLocalCount()

            guard let url = syncFileURL else { return }
            let today = todayString()

            coordinatedSync(to: url, forceMerge: false) { existingData in
                var syncData = existingData
                if syncData.devices[self.deviceID] == nil {
                    syncData.devices[self.deviceID] = DeviceData()
                }
                syncData.devices[self.deviceID]?.setCount(0, for: today)
                return syncData
            }

            let syncData = loadSyncData(from: url)
            totalKeystrokeCount = syncData.totalCount(for: today)

            updateMenuBarTitle()
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

    @objc private func checkForUpdates() {
        updateChecker.checkForUpdates()
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
            callback: { (_, _, event, refcon) -> Unmanaged<CGEvent>? in
                if let refcon = refcon {
                    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                    appDelegate.handleKeyEvent()
                }
                return Unmanaged.passRetained(event)
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

    func handleKeyEvent() {
        checkDayChange()

        localKeystrokeCount += 1
        totalKeystrokeCount += 1

        updateMenuBarTitle()

        if localKeystrokeCount % 50 == 0 {
            saveLocalCount()
        }

        if localKeystrokeCount % 1000 == 0 {
            syncToCloud()
        }
    }
}

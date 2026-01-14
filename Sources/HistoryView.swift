import SwiftUI
import Charts
import Cocoa
import Combine

// MARK: - Data Store for Reactive Updates

class HistoryDataStore: ObservableObject {
    @Published var syncData: SyncData
    let dataFileURL: URL?
    private let fileCoordinator = NSFileCoordinator()
    
    init(syncData: SyncData, dataFileURL: URL?) {
        self.syncData = syncData
        self.dataFileURL = dataFileURL
    }
    
    func reload() {
        guard let url = dataFileURL else { return }
        var coordinatorError: NSError?
        
        // Note: fileCoordinator.coordinate may call its closure on a background thread,
        // so we dispatch the @Published property update to main thread for thread safety
        fileCoordinator.coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinatorError
        ) { coordURL in
            guard FileManager.default.fileExists(atPath: coordURL.path),
                  let data = try? Data(contentsOf: coordURL),
                  let newSyncData = try? JSONDecoder().decode(SyncData.self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                self.syncData = newSyncData
            }
        }
    }
}

// MARK: - Data Models

struct AppBreakdown: Identifiable, Equatable {
    let id: String  // Use bundleID as stable ID
    let bundleID: String
    let displayName: String
    let count: Int
    let color: Color

    init(bundleID: String, displayName: String, count: Int, color: Color) {
        self.id = bundleID
        self.bundleID = bundleID
        self.displayName = displayName
        self.count = count
        self.color = color
    }

    static func == (lhs: AppBreakdown, rhs: AppBreakdown) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.count == rhs.count
    }
}

struct DailyDataWithApps: Identifiable, Equatable {
    let id: String  // Use dateString as stable ID
    let date: Date
    let dateString: String
    let totalCount: Int
    let appBreakdown: [AppBreakdown]

    init(date: Date, dateString: String, totalCount: Int, appBreakdown: [AppBreakdown]) {
        self.id = dateString
        self.date = date
        self.dateString = dateString
        self.totalCount = totalCount
        self.appBreakdown = appBreakdown
    }

    static func == (lhs: DailyDataWithApps, rhs: DailyDataWithApps) -> Bool {
        lhs.dateString == rhs.dateString && lhs.totalCount == rhs.totalCount && lhs.appBreakdown == rhs.appBreakdown
    }
}

// MARK: - App Color & Name Utilities

struct AppColorManager {
    // Reverse rainbow colors starting from red
    static let colors: [Color] = [
        .red,
        .orange,
        .yellow,
        .green,
        .cyan,
        .blue,
        .indigo,
        .purple,
        .pink,
        .mint
    ]

    static let othersColor = Color.gray

    static func color(for index: Int) -> Color {
        if index < colors.count {
            return colors[index]
        }
        return othersColor
    }
}

class AppDisplayNameCache {
    static let shared = AppDisplayNameCache()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    func displayName(for bundleID: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[bundleID] {
            return cached
        }

        let name = resolveDisplayName(for: bundleID)
        cache[bundleID] = name
        return name
    }

    private func resolveDisplayName(for bundleID: String) -> String {
        if bundleID == "unknown" {
            return "Unknown"
        }
        if bundleID == "others" {
            return "Others"
        }

        // Try to get the running application's localized name
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }

        // Try to get app name from bundle URL
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: bundleURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }

        // Fallback: extract app name from bundle ID
        let components = bundleID.components(separatedBy: ".")
        if let lastComponent = components.last {
            return lastComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }
        return bundleID
    }
}

func getAppDisplayName(for bundleID: String) -> String {
    AppDisplayNameCache.shared.displayName(for: bundleID)
}

// MARK: - Chart Section (Isolated to prevent re-renders)

struct ChartSection: View, Equatable {
    let chartData: [DailyDataWithApps]
    let selectedDays: Int

    static func == (lhs: ChartSection, rhs: ChartSection) -> Bool {
        lhs.chartData == rhs.chartData && lhs.selectedDays == rhs.selectedDays
    }

    var body: some View {
        Chart {
            ForEach(chartData) { day in
                ForEach(day.appBreakdown) { app in
                    BarMark(
                        x: .value("Date", day.date, unit: .day),
                        y: .value("Count", app.count)
                    )
                    .foregroundStyle(app.color)
                }
            }
        }
        .frame(height: 150)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, selectedDays / 7))) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }
}

// MARK: - History View

struct HistoryView: View {
    @ObservedObject var dataStore: HistoryDataStore
    @State private var selectedDays = 7
    @State private var hiddenApps: Set<String> = []  // bundleIDs to hide from stats
    @State private var expandedDays: Set<String> = []  // dateStrings of expanded rows
    @State private var cachedTopApps: [(bundleID: String, count: Int, color: Color)] = []

    // Top 5 apps for current period + Others (including untracked)
    private func computeTopAppsForPeriod() -> [(bundleID: String, count: Int, color: Color)] {
        let appCounts = dataStore.syncData.totalAppCounts(forDays: selectedDays, from: Date())
        let sorted = appCounts.sorted { $0.value > $1.value }
        
        // Calculate total keystrokes vs tracked keystrokes for the period
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var totalKeystrokes = 0
        var trackedKeystrokes = 0
        for i in 0..<selectedDays {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let dateString = formatter.string(from: date)
            totalKeystrokes += dataStore.syncData.totalCount(for: dateString)
            trackedKeystrokes += dataStore.syncData.totalAppCounts(for: dateString).values.reduce(0, +)
        }
        let untrackedCount = totalKeystrokes - trackedKeystrokes
        
        var result: [(bundleID: String, count: Int, color: Color)] = []
        var othersCount = 0
        
        for (index, item) in sorted.enumerated() {
            if index < 5 {
                result.append((item.key, item.value, AppColorManager.color(for: index)))
            } else {
                othersCount += item.value
            }
        }
        
        // Include untracked keystrokes in "Others"
        othersCount += untrackedCount
        
        if othersCount > 0 {
            result.append(("others", othersCount, AppColorManager.othersColor))
        }
        
        return result
    }

    private func updateCachedTopApps() {
        cachedTopApps = computeTopAppsForPeriod()
    }

    private var dailyData: [DailyDataWithApps] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        // Use cached top apps for consistent colors (avoids redundant computation)
        let topApps = cachedTopApps.map { $0.bundleID }
        
        var data: [DailyDataWithApps] = []
        for i in 0..<selectedDays {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let dateString = formatter.string(from: date)
            let totalCount = dataStore.syncData.totalCount(for: dateString)
            let dayAppCounts = dataStore.syncData.totalAppCounts(for: dateString)
            
            var breakdown: [AppBreakdown] = []
            var othersCount = 0
            
            // Group into top 5 + others
            for (bundleID, count) in dayAppCounts {
                if let index = topApps.firstIndex(of: bundleID), index < 5 {
                    if !hiddenApps.contains(bundleID) {
                        breakdown.append(AppBreakdown(
                            bundleID: bundleID,
                            displayName: getAppDisplayName(for: bundleID),
                            count: count,
                            color: AppColorManager.color(for: index)
                        ))
                    }
                } else {
                    if !hiddenApps.contains("others") {
                        othersCount += count
                    }
                }
            }
            
            // Calculate sum of tracked app counts and add untracked to others
            let trackedTotal = dayAppCounts.values.reduce(0, +)
            let untrackedCount = totalCount - trackedTotal
            if untrackedCount > 0 && !hiddenApps.contains("others") {
                othersCount += untrackedCount
            }
            
            if othersCount > 0 {
                breakdown.append(AppBreakdown(
                    bundleID: "others",
                    displayName: "Others",
                    count: othersCount,
                    color: AppColorManager.othersColor
                ))
            }
            
            // If no app data at all, use the total count as "All Apps" (legacy data)
            // Only show if "others" is not hidden (legacy data is effectively untracked)
            if breakdown.isEmpty && totalCount > 0 && !hiddenApps.contains("others") {
                breakdown.append(AppBreakdown(
                    bundleID: "others",
                    displayName: "Others",
                    count: totalCount,
                    color: AppColorManager.othersColor
                ))
            }
            
            // Calculate displayed total (respecting hidden apps filter)
            let displayedTotal = breakdown.reduce(0) { $0 + $1.count }
            
            data.append(DailyDataWithApps(
                date: date,
                dateString: dateString,
                totalCount: displayedTotal,
                appBreakdown: breakdown.sorted { $0.count > $1.count }
            ))
        }
        return data
    }
    
    private var chartData: [DailyDataWithApps] {
        Array(dailyData.reversed())
    }
    
    private let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
    
    var body: some View {
        VStack(spacing: 0) {
            // Chart section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Keystroke History")
                        .font(.headline)
                    Spacer()
                    Picker("", selection: $selectedDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                
                // Stacked bar chart (isolated to prevent flicker on row expand)
                EquatableView(content: ChartSection(chartData: chartData, selectedDays: selectedDays))
                
                // Legend with toggle filtering (uses cached top apps)
                HStack(spacing: 16) {
                    ForEach(cachedTopApps, id: \.bundleID) { app in
                        LegendItem(
                            bundleID: app.bundleID,
                            displayName: getAppDisplayName(for: app.bundleID),
                            color: app.color,
                            count: app.count,
                            isHidden: hiddenApps.contains(app.bundleID)
                        ) {
                            if hiddenApps.contains(app.bundleID) {
                                hiddenApps.remove(app.bundleID)
                            } else {
                                hiddenApps.insert(app.bundleID)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding()
            
            Divider()
            
            // List section with expandable rows
            List(dailyData) { item in
                DayRow(
                    item: item,
                    isExpanded: expandedDays.contains(item.dateString),
                    displayFormatter: displayFormatter,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedDays.contains(item.dateString) {
                                expandedDays.remove(item.dateString)
                            } else {
                                expandedDays.insert(item.dateString)
                            }
                        }
                    }
                )
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button("Open Data Folder") {
                    if let url = dataStore.dataFileURL {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                }
                .buttonStyle(.link)
                .padding()
            }
        }
        .frame(width: 540, height: 550)
        .onAppear {
            updateCachedTopApps()
        }
        .onChange(of: selectedDays) { _ in
            updateCachedTopApps()
        }
        .onReceive(dataStore.$syncData) { _ in
            updateCachedTopApps()
        }
    }

    private func formatNumber(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Legend Item

struct LegendItem: View {
    let bundleID: String
    let displayName: String
    let color: Color
    let count: Int
    let isHidden: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isHidden ? Color.gray.opacity(0.3) : color)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(color, lineWidth: isHidden ? 1 : 0)
                    )
                Text(displayName)
                    .font(.caption)
                    .foregroundColor(isHidden ? .secondary : .primary)
                    .strikethrough(isHidden)
            }
        }
        .buttonStyle(.plain)
        .help("\(displayName): \(formatCount(count)) keystrokes")
    }

    private func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Day Row (Expandable)

struct DayRow: View {
    let item: DailyDataWithApps
    let isExpanded: Bool
    let displayFormatter: DateFormatter
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - clickable header
            Button(action: onToggle) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Text(displayFormatter.string(from: item.date))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(formatNumber(item.totalCount))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content - app breakdown
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.appBreakdown) { app in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(app.color)
                                .frame(width: 8, height: 8)
                            Text(app.displayName)
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatNumber(app.count))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 20)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
        }
    }

    private func formatNumber(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - Window Controller with Auto-Refresh

class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private static let frameKey = "HistoryWindowFrame"
    private var dataStore: HistoryDataStore?
    private var refreshTimer: Timer?
    
    convenience init(syncData: SyncData, dataFileURL: URL?) {
        let store = HistoryDataStore(syncData: syncData, dataFileURL: dataFileURL)
        let hostingController = NSHostingController(rootView: HistoryView(dataStore: store))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Typing Stats History"
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 420, height: 450)
        
        if let frameString = UserDefaults.standard.string(forKey: HistoryWindowController.frameKey) {
            window.setFrame(NSRectFromString(frameString), display: false)
        } else {
            window.setContentSize(NSSize(width: 540, height: 550))
            window.center()
        }
        
        self.init(window: window)
        self.dataStore = store
        window.delegate = self
        
        // Start periodic refresh timer (every 5 minutes)
        startRefreshTimer()
    }
    
    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.dataStore?.reload()
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Refresh data when window gains focus
        dataStore?.reload()
    }
    
    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: HistoryWindowController.frameKey)
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

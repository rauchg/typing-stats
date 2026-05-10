import Foundation

// MARK: - Sync Data Models

struct DailyCount: Codable {
    var count: Int
    var lastModified: TimeInterval
    var appCounts: [String: Int]?  // bundleID -> count (optional for backwards compatibility)

    init(count: Int, appCounts: [String: Int]? = nil) {
        self.count = count
        self.lastModified = Date().timeIntervalSince1970
        self.appCounts = appCounts
    }
}

struct DeviceData: Codable {
    var dailyCounts: [String: DailyCount]

    init() {
        dailyCounts = [:]
    }

    mutating func setCount(_ count: Int, for date: String, appCounts: [String: Int]? = nil) {
        dailyCounts[date] = DailyCount(count: count, appCounts: appCounts)
    }

    func count(for date: String) -> Int {
        dailyCounts[date]?.count ?? 0
    }

    func appCounts(for date: String) -> [String: Int] {
        dailyCounts[date]?.appCounts ?? [:]
    }

    mutating func pruneOldData(keepingDays: Int = 60) {
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -keepingDays, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffString = formatter.string(from: cutoffDate)

        dailyCounts = dailyCounts.filter { $0.key >= cutoffString }
    }
}

struct SyncData: Codable {
    var devices: [String: DeviceData]
    var version: Int

    init() {
        devices = [:]
        version = 2
    }

    func totalCount(for date: String) -> Int {
        devices.values.reduce(0) { $0 + $1.count(for: date) }
    }

    /// Aggregate app counts across all devices for a specific date
    func totalAppCounts(for date: String) -> [String: Int] {
        var aggregated: [String: Int] = [:]
        for device in devices.values {
            for (bundleID, count) in device.appCounts(for: date) {
                aggregated[bundleID, default: 0] += count
            }
        }
        return aggregated
    }

    /// Aggregate app counts across all devices for a date range
    func totalAppCounts(forDays days: Int, from date: Date) -> [String: Int] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        var aggregated: [String: Int] = [:]
        for i in 0..<days {
            guard let pastDate = calendar.date(byAdding: .day, value: -i, to: date) else { continue }
            let dateString = formatter.string(from: pastDate)
            for (bundleID, count) in totalAppCounts(for: dateString) {
                aggregated[bundleID, default: 0] += count
            }
        }
        return aggregated
    }

    func recordDay() -> (count: Int, date: String)? {
        var allDates = Set<String>()
        for device in devices.values {
            allDates.formUnion(device.dailyCounts.keys)
        }

        var maxCount = 0
        var maxDate: String?

        for date in allDates {
            let count = totalCount(for: date)
            if count > maxCount {
                maxCount = count
                maxDate = date
            }
        }

        guard let date = maxDate else { return nil }
        return (maxCount, date)
    }

    /// Consecutive days ending today, or yesterday when today has no typing yet.
    func currentStreak(from referenceDate: Date = Date()) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        let referenceDateString = formatter.string(from: referenceDate)
        let startOffset = totalCount(for: referenceDateString) > 0 ? 0 : 1

        var streak = 0
        var dayOffset = startOffset
        while let date = calendar.date(byAdding: .day, value: -dayOffset, to: referenceDate) {
            let dateString = formatter.string(from: date)
            if totalCount(for: dateString) > 0 {
                streak += 1
                dayOffset += 1
            } else {
                break
            }

            if dayOffset > 3650 { break }
        }

        return streak
    }

    /// Longest run of consecutive days with totalCount > 0.
    func longestStreak() -> (count: Int, endDate: String)? {
        var allDates = Set<String>()
        for device in devices.values {
            allDates.formUnion(device.dailyCounts.keys)
        }

        let sortedDates = allDates.sorted()
        guard !sortedDates.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        var bestCount = 0
        var bestEndDate: String?
        var runCount = 0
        var previousDate: Date?

        for dateString in sortedDates {
            guard let date = formatter.date(from: dateString) else { continue }

            if totalCount(for: dateString) == 0 {
                runCount = 0
                previousDate = nil
                continue
            }

            if let previous = previousDate,
               let expectedDate = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(expectedDate, inSameDayAs: date) {
                runCount += 1
            } else {
                runCount = 1
            }

            previousDate = date

            if runCount > bestCount {
                bestCount = runCount
                bestEndDate = dateString
            }
        }

        guard let endDate = bestEndDate else { return nil }
        return (bestCount, endDate)
    }

    func averageCount(forLastDays days: Int, from date: Date) -> Double {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current

        var total = 0
        var daysWithData = 0

        for i in 0..<days {
            guard let pastDate = calendar.date(byAdding: .day, value: -i, to: date) else { continue }
            let dateString = formatter.string(from: pastDate)
            let count = totalCount(for: dateString)
            if count > 0 {
                total += count
                daysWithData += 1
            }
        }

        return daysWithData > 0 ? Double(total) / Double(daysWithData) : 0
    }

    mutating func merge(with other: SyncData) {
        for (deviceID, otherDeviceData) in other.devices {
            if devices[deviceID] == nil {
                devices[deviceID] = DeviceData()
            }

            for (date, otherDailyCount) in otherDeviceData.dailyCounts {
                if let existing = devices[deviceID]?.dailyCounts[date] {
                    if otherDailyCount.count > existing.count {
                        devices[deviceID]?.dailyCounts[date] = otherDailyCount
                    } else if otherDailyCount.count == existing.count {
                        // Same count - merge app counts from both
                        var mergedAppCounts = existing.appCounts ?? [:]
                        if let otherAppCounts = otherDailyCount.appCounts {
                            for (bundleID, count) in otherAppCounts {
                                mergedAppCounts[bundleID] = max(mergedAppCounts[bundleID] ?? 0, count)
                            }
                        }
                        devices[deviceID]?.dailyCounts[date]?.appCounts = mergedAppCounts.isEmpty ? nil : mergedAppCounts
                    }
                } else {
                    devices[deviceID]?.dailyCounts[date] = otherDailyCount
                }
            }
        }
    }

    mutating func pruneAllDevices(keepingDays: Int = 60) {
        for deviceID in devices.keys {
            devices[deviceID]?.pruneOldData(keepingDays: keepingDays)
        }
    }
}

// MARK: - Local State

struct LocalState: Codable {
    var date: String
    var count: Int
    var appCounts: [String: Int]?  // bundleID -> count (optional for backwards compatibility)
}

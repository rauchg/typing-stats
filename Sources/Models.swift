import Foundation

// MARK: - Sync Data Models

struct DailyCount: Codable {
    var count: Int
    var lastModified: TimeInterval

    init(count: Int) {
        self.count = count
        self.lastModified = Date().timeIntervalSince1970
    }
}

struct DeviceData: Codable {
    var dailyCounts: [String: DailyCount]

    init() {
        dailyCounts = [:]
    }

    mutating func setCount(_ count: Int, for date: String) {
        dailyCounts[date] = DailyCount(count: count)
    }

    func count(for date: String) -> Int {
        dailyCounts[date]?.count ?? 0
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
}

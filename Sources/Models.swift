import Foundation

// MARK: - Count Filter

/// Which input source to include when reading counts.
/// `count` / `appCounts` always include dictated characters; dictation is a labeled subset.
enum CountFilter: String, CaseIterable {
    case all = "All"
    case typed = "Typed"
    case dictated = "Dictated"
}

// MARK: - Sync Limits & Safe Arithmetic

enum SyncLimits {
    /// Maximum keystrokes/characters accepted per device per day when decoding or accumulating.
    /// High enough to never clip real usage (10M/day), low enough to prevent Int overflow across devices.
    static let maxDailyCount: Int = 10_000_000
    /// Seconds in a calendar day (24h), used to clamp per-day typing/speaking durations.
    static let maxDailySeconds: Double = 86_400
    /// Upper bound on computed WPM so corrupted/hand-edited sync files cannot produce unrepresentable Doubles.
    static let maxWPM: Double = 10_000

    static func clampCount(_ value: Int?) -> Int {
        guard let value = value, value > 0 else { return 0 }
        return min(value, maxDailyCount)
    }

    static func clampSeconds(_ value: Double?) -> Double {
        guard let value = value, value.isFinite, value > 0 else { return 0 }
        return min(value, maxDailySeconds)
    }

    static func sanitizeAppCounts(_ counts: [String: Int]?) -> [String: Int] {
        guard let counts = counts else { return [:] }
        var sanitized: [String: Int] = [:]
        sanitized.reserveCapacity(counts.count)
        for (bundleID, raw) in counts {
            let clamped = clampCount(raw)
            if clamped > 0 {
                sanitized[bundleID] = clamped
            }
        }
        return sanitized
    }
}

// MARK: - Day Extras

/// Per-day dictation and speed metrics, stored next to the keystroke count.
/// All fields are optional in JSON so older files and older app versions keep working.
struct DayExtras: Codable, Equatable {
    /// Characters inserted by dictation apps (a subset of `count`).
    var dictatedCount: Int = 0
    /// bundleID of the target app -> dictated characters (a subset of `appCounts`).
    var dictatedAppCounts: [String: Int] = [:]
    /// Active typing time (sum of gaps between hardware keystrokes ≤ typingIdleThreshold).
    var typingSeconds: Double = 0
    /// Keystrokes that fell inside timed typing bursts (numerator for typing WPM).
    var typingKeys: Int = 0
    /// Time the dictation app held the microphone open, for utterances we could time.
    var speakingSeconds: Double = 0
    /// Dictated characters belonging to timed utterances (numerator for speaking WPM).
    var speakingChars: Int = 0

    init(dictatedCount: Int = 0, dictatedAppCounts: [String: Int] = [:], typingSeconds: Double = 0,
         typingKeys: Int = 0, speakingSeconds: Double = 0, speakingChars: Int = 0) {
        self.dictatedCount = SyncLimits.clampCount(dictatedCount)
        self.dictatedAppCounts = SyncLimits.sanitizeAppCounts(dictatedAppCounts)
        self.typingSeconds = SyncLimits.clampSeconds(typingSeconds)
        self.typingKeys = SyncLimits.clampCount(typingKeys)
        self.speakingSeconds = SyncLimits.clampSeconds(speakingSeconds)
        self.speakingChars = SyncLimits.clampCount(speakingChars)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawDictatedCount = try c.decodeIfPresent(Int.self, forKey: .dictatedCount)
        let rawDictatedAppCounts = try c.decodeIfPresent([String: Int].self, forKey: .dictatedAppCounts)
        let rawTypingSeconds = try c.decodeIfPresent(Double.self, forKey: .typingSeconds)
        let rawTypingKeys = try c.decodeIfPresent(Int.self, forKey: .typingKeys)
        let rawSpeakingSeconds = try c.decodeIfPresent(Double.self, forKey: .speakingSeconds)
        let rawSpeakingChars = try c.decodeIfPresent(Int.self, forKey: .speakingChars)
        self.init(
            dictatedCount: rawDictatedCount ?? 0,
            dictatedAppCounts: rawDictatedAppCounts ?? [:],
            typingSeconds: rawTypingSeconds ?? 0,
            typingKeys: rawTypingKeys ?? 0,
            speakingSeconds: rawSpeakingSeconds ?? 0,
            speakingChars: rawSpeakingChars ?? 0
        )
    }

    var isEmpty: Bool { self == DayExtras() }

    /// Field-wise max, used when two copies of the same device/day disagree.
    func merged(with other: DayExtras) -> DayExtras {
        var r = DayExtras()
        r.dictatedCount = max(dictatedCount, other.dictatedCount)
        r.dictatedAppCounts = dictatedAppCounts.merging(other.dictatedAppCounts) { max($0, $1) }
        r.typingSeconds = max(typingSeconds, other.typingSeconds)
        r.typingKeys = max(typingKeys, other.typingKeys)
        r.speakingSeconds = max(speakingSeconds, other.speakingSeconds)
        r.speakingChars = max(speakingChars, other.speakingChars)
        return r
    }
}

extension Int {
    /// Addition/subtraction that clamp instead of trapping; inputs can come from the shared sync file.
    func saturatingAdd(_ other: Int) -> Int {
        let (r, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : r
    }
    func saturatingSubtract(_ other: Int) -> Int {
        let (r, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other < 0 ? .max : .min) : r
    }
}

extension DayExtras {
    /// Sum of two days' extras (used to aggregate devices/date ranges). Saturates on overflow.
    func adding(_ o: DayExtras) -> DayExtras {
        var r = self
        r.dictatedCount = dictatedCount.saturatingAdd(o.dictatedCount)
        for (bundleID, count) in o.dictatedAppCounts {
            r.dictatedAppCounts[bundleID] = (r.dictatedAppCounts[bundleID] ?? 0).saturatingAdd(count)
        }
        r.typingSeconds += SyncLimits.clampSeconds(o.typingSeconds)
        r.typingKeys = typingKeys.saturatingAdd(o.typingKeys)
        r.speakingSeconds += SyncLimits.clampSeconds(o.speakingSeconds)
        r.speakingChars = speakingChars.saturatingAdd(o.speakingChars)
        return r
    }
}

/// Words per minute using the standard 5-characters-per-word convention.
func wordsPerMinute(chars: Int, seconds: Double) -> Double? {
    guard seconds.isFinite, seconds >= 1, chars > 0 else { return nil }
    let wpm = (Double(chars) / 5.0) / (seconds / 60.0)
    guard wpm.isFinite, wpm > 0, wpm <= SyncLimits.maxWPM else { return nil }
    return wpm
}

// MARK: - Sync Data Models

struct DailyCount: Codable {
    var count: Int
    var lastModified: TimeInterval
    var appCounts: [String: Int]?  // bundleID -> count (optional for backwards compatibility)
    // Dictation / speed fields (optional for backwards compatibility)
    var dictatedCount: Int?
    var dictatedAppCounts: [String: Int]?
    var typingSeconds: Double?
    var typingKeys: Int?
    var speakingSeconds: Double?
    var speakingChars: Int?

    init(count: Int, appCounts: [String: Int]? = nil, extras: DayExtras = DayExtras()) {
        self.count = SyncLimits.clampCount(count)
        self.lastModified = Date().timeIntervalSince1970
        let sanitizedApps = SyncLimits.sanitizeAppCounts(appCounts)
        self.appCounts = sanitizedApps.isEmpty ? nil : sanitizedApps
        self.extras = extras
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawCount = try c.decode(Int.self, forKey: .count)
        self.count = SyncLimits.clampCount(rawCount)

        let rawModified = try c.decodeIfPresent(TimeInterval.self, forKey: .lastModified) ?? 0
        self.lastModified = (rawModified.isFinite && rawModified >= 0) ? rawModified : 0

        let sanitizedApps = SyncLimits.sanitizeAppCounts(try c.decodeIfPresent([String: Int].self, forKey: .appCounts))
        self.appCounts = sanitizedApps.isEmpty ? nil : sanitizedApps

        let decodedExtras = DayExtras(
            dictatedCount: try c.decodeIfPresent(Int.self, forKey: .dictatedCount) ?? 0,
            dictatedAppCounts: try c.decodeIfPresent([String: Int].self, forKey: .dictatedAppCounts) ?? [:],
            typingSeconds: try c.decodeIfPresent(Double.self, forKey: .typingSeconds) ?? 0,
            typingKeys: try c.decodeIfPresent(Int.self, forKey: .typingKeys) ?? 0,
            speakingSeconds: try c.decodeIfPresent(Double.self, forKey: .speakingSeconds) ?? 0,
            speakingChars: try c.decodeIfPresent(Int.self, forKey: .speakingChars) ?? 0
        )
        self.extras = decodedExtras
    }

    /// Sanitized view of the dictation/speed fields. The sync file is shared via iCloud and can be
    /// edited by other devices or by hand, so negative, non-finite, and oversized values are clamped.
    var extras: DayExtras {
        get {
            DayExtras(
                dictatedCount: dictatedCount ?? 0,
                dictatedAppCounts: dictatedAppCounts ?? [:],
                typingSeconds: typingSeconds ?? 0,
                typingKeys: typingKeys ?? 0,
                speakingSeconds: speakingSeconds ?? 0,
                speakingChars: speakingChars ?? 0
            )
        }
        set {
            let clamped = DayExtras(
                dictatedCount: newValue.dictatedCount,
                dictatedAppCounts: newValue.dictatedAppCounts,
                typingSeconds: newValue.typingSeconds,
                typingKeys: newValue.typingKeys,
                speakingSeconds: newValue.speakingSeconds,
                speakingChars: newValue.speakingChars
            )
            dictatedCount = clamped.dictatedCount > 0 ? clamped.dictatedCount : nil
            dictatedAppCounts = clamped.dictatedAppCounts.isEmpty ? nil : clamped.dictatedAppCounts
            typingSeconds = clamped.typingSeconds > 0 ? clamped.typingSeconds : nil
            typingKeys = clamped.typingKeys > 0 ? clamped.typingKeys : nil
            speakingSeconds = clamped.speakingSeconds > 0 ? clamped.speakingSeconds : nil
            speakingChars = clamped.speakingChars > 0 ? clamped.speakingChars : nil
        }
    }
}

struct DeviceData: Codable {
    var dailyCounts: [String: DailyCount]

    init() {
        dailyCounts = [:]
    }

    mutating func setCount(_ count: Int, for date: String, appCounts: [String: Int]? = nil, extras: DayExtras = DayExtras()) {
        dailyCounts[date] = DailyCount(count: count, appCounts: appCounts, extras: extras)
    }

    func count(for date: String) -> Int {
        dailyCounts[date]?.count ?? 0
    }

    func appCounts(for date: String) -> [String: Int] {
        dailyCounts[date]?.appCounts ?? [:]
    }

    func extras(for date: String) -> DayExtras {
        dailyCounts[date]?.extras ?? DayExtras()
    }

    mutating func pruneOldData(keepingDays: Int = 60) {
        let calendar = Calendar.current
        let now = Date()
        guard let cutoffDate = calendar.date(byAdding: .day, value: -keepingDays, to: now),
              let maxDate = calendar.date(byAdding: .day, value: 1, to: now) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffString = formatter.string(from: cutoffDate)
        let maxString = formatter.string(from: maxDate)

        dailyCounts = dailyCounts.filter { key, _ in
            guard key.count == 10, formatter.date(from: key) != nil else { return false }
            return key >= cutoffString && key <= maxString
        }
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
        devices.values.reduce(0) { $0.saturatingAdd($1.count(for: date)) }
    }

    /// Extras summed across devices for a date.
    func totalExtras(for date: String) -> DayExtras {
        devices.values.reduce(DayExtras()) { $0.adding($1.extras(for: date)) }
    }

    /// Extras summed across devices for the last `days` days ending at `date`.
    func totalExtras(forDays days: Int, from date: Date) -> DayExtras {
        Self.dateStrings(days: days, from: date).reduce(DayExtras()) { $0.adding(totalExtras(for: $1)) }
    }

    func totalCount(for date: String, filter: CountFilter) -> Int {
        let total = totalCount(for: date)
        switch filter {
        case .all: return total
        case .dictated: return min(total, totalExtras(for: date).dictatedCount)
        case .typed: return max(0, total.saturatingSubtract(totalExtras(for: date).dictatedCount))
        }
    }

    func totalAppCounts(for date: String, filter: CountFilter) -> [String: Int] {
        switch filter {
        case .all:
            return totalAppCounts(for: date)
        case .dictated:
            return totalExtras(for: date).dictatedAppCounts
        case .typed:
            var counts = totalAppCounts(for: date)
            for (bundleID, dictated) in totalExtras(for: date).dictatedAppCounts {
                let remaining = (counts[bundleID] ?? 0).saturatingSubtract(dictated)
                counts[bundleID] = remaining > 0 ? remaining : nil
            }
            return counts
        }
    }

    func totalAppCounts(forDays days: Int, from date: Date, filter: CountFilter) -> [String: Int] {
        var aggregated: [String: Int] = [:]
        for dateString in Self.dateStrings(days: days, from: date) {
            for (bundleID, count) in totalAppCounts(for: dateString, filter: filter) {
                aggregated[bundleID] = (aggregated[bundleID] ?? 0).saturatingAdd(count)
            }
        }
        return aggregated
    }

    /// (typing WPM, speaking WPM) for a period; nil when there's no timed data.
    func wpm(forDays days: Int, from date: Date) -> (typing: Double?, speaking: Double?) {
        let e = totalExtras(forDays: days, from: date)
        return (wordsPerMinute(chars: e.typingKeys, seconds: e.typingSeconds),
                wordsPerMinute(chars: e.speakingChars, seconds: e.speakingSeconds))
    }

    private static func dateStrings(days: Int, from date: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        return (0..<max(0, days)).compactMap { i in
            calendar.date(byAdding: .day, value: -i, to: date).map { formatter.string(from: $0) }
        }
    }

    /// Aggregate app counts across all devices for a specific date
    func totalAppCounts(for date: String) -> [String: Int] {
        var aggregated: [String: Int] = [:]
        for device in devices.values {
            for (bundleID, count) in device.appCounts(for: date) {
                aggregated[bundleID] = (aggregated[bundleID] ?? 0).saturatingAdd(count)
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
                aggregated[bundleID] = (aggregated[bundleID] ?? 0).saturatingAdd(count)
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
                total = total.saturatingAdd(count)
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
                        // Same count - keep the larger dictation/speed figures from either copy
                        devices[deviceID]?.dailyCounts[date]?.extras = existing.extras.merged(with: otherDailyCount.extras)
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

extension Double {
    /// Converts a rounded Double to Int without trapping on NaN, infinity, or out-of-range values.
    var roundedClampedInt: Int {
        guard isFinite else { return 0 }
        let r = rounded()
        if r <= Double(Int.min) { return .min }
        if r >= Double(Int.max) { return .max }
        return Int(r)
    }
}

// MARK: - Local State

struct LocalState: Codable {
    var date: String
    var count: Int
    var appCounts: [String: Int]?  // bundleID -> count (optional for backwards compatibility)
    var extras: DayExtras?         // dictation / speed metrics (optional for backwards compatibility)

    init(date: String, count: Int, appCounts: [String: Int]? = nil, extras: DayExtras? = nil) {
        self.date = date
        self.count = SyncLimits.clampCount(count)
        let sanitizedApps = SyncLimits.sanitizeAppCounts(appCounts)
        self.appCounts = sanitizedApps.isEmpty ? nil : sanitizedApps
        self.extras = extras
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let date = try c.decode(String.self, forKey: .date)
        let rawCount = try c.decode(Int.self, forKey: .count)
        let rawAppCounts = try c.decodeIfPresent([String: Int].self, forKey: .appCounts)
        let rawExtras = try c.decodeIfPresent(DayExtras.self, forKey: .extras)
        self.init(date: date, count: rawCount, appCounts: rawAppCounts, extras: rawExtras)
    }
}

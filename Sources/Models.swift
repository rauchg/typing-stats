import Foundation

// MARK: - Count Filter

/// Which input source to include when reading counts.
/// `count` / `appCounts` always include dictated characters; dictation is a labeled subset.
/// `agents` isn't keystrokes: it reads characters coding agents wrote, broken down by project.
enum CountFilter: String, CaseIterable {
    case all = "All"
    case typed = "Typed"
    case dictated = "Dictated"
    case agents = "Agents"
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
        self.dictatedCount = dictatedCount
        self.dictatedAppCounts = dictatedAppCounts
        self.typingSeconds = typingSeconds
        self.typingKeys = typingKeys
        self.speakingSeconds = speakingSeconds
        self.speakingChars = speakingChars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictatedCount = try c.decodeIfPresent(Int.self, forKey: .dictatedCount) ?? 0
        dictatedAppCounts = try c.decodeIfPresent([String: Int].self, forKey: .dictatedAppCounts) ?? [:]
        typingSeconds = try c.decodeIfPresent(Double.self, forKey: .typingSeconds) ?? 0
        typingKeys = try c.decodeIfPresent(Int.self, forKey: .typingKeys) ?? 0
        speakingSeconds = try c.decodeIfPresent(Double.self, forKey: .speakingSeconds) ?? 0
        speakingChars = try c.decodeIfPresent(Int.self, forKey: .speakingChars) ?? 0
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
        r.typingSeconds += o.typingSeconds
        r.typingKeys = typingKeys.saturatingAdd(o.typingKeys)
        r.speakingSeconds += o.speakingSeconds
        r.speakingChars = speakingChars.saturatingAdd(o.speakingChars)
        return r
    }
}

// MARK: - Coding Agents

/// Coding agents whose local session logs we read. Raw values are the keys in the sync file.
enum AgentKind: String, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case opencode
    case fx

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        case .fx: return "fx"
        }
    }

    static func displayName(for key: String) -> String {
        AgentKind(rawValue: key)?.displayName ?? key
    }
}

/// One agent's activity on one day, derived from its local session logs. Only counts, never
/// prompt or code text. All fields are optional in JSON so older and newer files keep working.
struct AgentDayStats: Codable, Equatable {
    /// Input tokens not served from cache.
    var inputTokens: Int = 0
    /// Output tokens, including reasoning/thinking.
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    /// Spend reported by the agent itself (only opencode records it); 0 when unknown.
    var costUSD: Double = 0
    /// Characters and lines the agent wrote into files through its edit tools.
    /// Edits made through shell commands (heredocs, sed…) can't be seen.
    var charsWritten: Int = 0
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    /// Prompts you sent the agent and their length in characters.
    var prompts: Int = 0
    var promptChars: Int = 0
    var toolCalls: Int = 0
    /// Time the agent spent working on turns.
    var activeSeconds: Double = 0
    /// Project (workspace folder name) -> characters written.
    var projectChars: [String: Int] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        // The sync file is shared via iCloud, so clamp anything negative or non-finite to 0.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ key: CodingKeys) throws -> Int { max(0, try c.decodeIfPresent(Int.self, forKey: key) ?? 0) }
        func s(_ key: CodingKeys) throws -> Double {
            guard let v = try c.decodeIfPresent(Double.self, forKey: key), v.isFinite, v > 0 else { return 0 }
            return v
        }
        inputTokens = try n(.inputTokens)
        outputTokens = try n(.outputTokens)
        cacheReadTokens = try n(.cacheReadTokens)
        cacheWriteTokens = try n(.cacheWriteTokens)
        costUSD = try s(.costUSD)
        charsWritten = try n(.charsWritten)
        linesAdded = try n(.linesAdded)
        linesRemoved = try n(.linesRemoved)
        prompts = try n(.prompts)
        promptChars = try n(.promptChars)
        toolCalls = try n(.toolCalls)
        activeSeconds = try s(.activeSeconds)
        projectChars = (try c.decodeIfPresent([String: Int].self, forKey: .projectChars) ?? [:]).filter { $0.value > 0 }
    }

    /// All input the model processed, cached or not.
    var totalInputTokens: Int { inputTokens.saturatingAdd(cacheReadTokens).saturatingAdd(cacheWriteTokens) }
    var totalTokens: Int { totalInputTokens.saturatingAdd(outputTokens) }
    var hasActivity: Bool { totalTokens > 0 || charsWritten > 0 || prompts > 0 || toolCalls > 0 }

    /// Characters the agent wrote per character you prompted; nil without both.
    var leverage: Double? {
        guard promptChars > 0, charsWritten > 0 else { return nil }
        return Double(charsWritten) / Double(promptChars)
    }

    /// Sum of two days' stats (used to aggregate agents/devices/date ranges). Saturates on overflow.
    func adding(_ o: AgentDayStats) -> AgentDayStats {
        var r = self
        r.inputTokens = inputTokens.saturatingAdd(o.inputTokens)
        r.outputTokens = outputTokens.saturatingAdd(o.outputTokens)
        r.cacheReadTokens = cacheReadTokens.saturatingAdd(o.cacheReadTokens)
        r.cacheWriteTokens = cacheWriteTokens.saturatingAdd(o.cacheWriteTokens)
        r.costUSD += o.costUSD
        r.charsWritten = charsWritten.saturatingAdd(o.charsWritten)
        r.linesAdded = linesAdded.saturatingAdd(o.linesAdded)
        r.linesRemoved = linesRemoved.saturatingAdd(o.linesRemoved)
        r.prompts = prompts.saturatingAdd(o.prompts)
        r.promptChars = promptChars.saturatingAdd(o.promptChars)
        r.toolCalls = toolCalls.saturatingAdd(o.toolCalls)
        r.activeSeconds += o.activeSeconds
        for (project, chars) in o.projectChars {
            r.projectChars[project] = (r.projectChars[project] ?? 0).saturatingAdd(chars)
        }
        return r
    }

    /// Field-wise max, used when two copies of the same device/day disagree. Each device rebuilds
    /// its days from logs that only grow, so the larger copy is the newer one; and when an agent
    /// deletes old logs, the smaller recount must not wipe what we already recorded.
    func merged(with o: AgentDayStats) -> AgentDayStats {
        var r = AgentDayStats()
        r.inputTokens = max(inputTokens, o.inputTokens)
        r.outputTokens = max(outputTokens, o.outputTokens)
        r.cacheReadTokens = max(cacheReadTokens, o.cacheReadTokens)
        r.cacheWriteTokens = max(cacheWriteTokens, o.cacheWriteTokens)
        r.costUSD = max(costUSD, o.costUSD)
        r.charsWritten = max(charsWritten, o.charsWritten)
        r.linesAdded = max(linesAdded, o.linesAdded)
        r.linesRemoved = max(linesRemoved, o.linesRemoved)
        r.prompts = max(prompts, o.prompts)
        r.promptChars = max(promptChars, o.promptChars)
        r.toolCalls = max(toolCalls, o.toolCalls)
        r.activeSeconds = max(activeSeconds, o.activeSeconds)
        r.projectChars = projectChars.merging(o.projectChars) { max($0, $1) }
        return r
    }
}

/// date ("yyyy-MM-dd") -> agent (`AgentKind` raw value) -> stats.
typealias AgentDays = [String: [String: AgentDayStats]]

/// Field-wise max merge of two copies of one device's agent days (see `AgentDayStats.merged`).
func mergingAgentDays(_ days: AgentDays, _ other: AgentDays) -> AgentDays {
    var result = days
    for (date, agents) in other {
        for (agent, stats) in agents {
            result[date, default: [:]][agent] = result[date]?[agent].map { $0.merged(with: stats) } ?? stats
        }
    }
    return result
}

/// Words per minute using the standard 5-characters-per-word convention.
func wordsPerMinute(chars: Int, seconds: Double) -> Double? {
    guard seconds >= 1, chars > 0 else { return nil }
    return (Double(chars) / 5.0) / (seconds / 60.0)
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
        self.count = count
        self.lastModified = Date().timeIntervalSince1970
        self.appCounts = appCounts
        self.extras = extras
    }

    /// Sanitized view of the dictation/speed fields. The sync file is shared via iCloud and can be
    /// edited by other devices or by hand, so negative and non-finite values are clamped to 0.
    var extras: DayExtras {
        get {
            func n(_ v: Int?) -> Int { max(0, v ?? 0) }
            func s(_ v: Double?) -> Double { guard let v = v, v.isFinite, v > 0 else { return 0 }; return v }
            return DayExtras(
                dictatedCount: n(dictatedCount),
                dictatedAppCounts: (dictatedAppCounts ?? [:]).filter { $0.value > 0 },
                typingSeconds: s(typingSeconds),
                typingKeys: n(typingKeys),
                speakingSeconds: s(speakingSeconds),
                speakingChars: n(speakingChars)
            )
        }
        set {
            dictatedCount = newValue.dictatedCount > 0 ? newValue.dictatedCount : nil
            dictatedAppCounts = newValue.dictatedAppCounts.isEmpty ? nil : newValue.dictatedAppCounts
            typingSeconds = newValue.typingSeconds > 0 ? newValue.typingSeconds : nil
            typingKeys = newValue.typingKeys > 0 ? newValue.typingKeys : nil
            speakingSeconds = newValue.speakingSeconds > 0 ? newValue.speakingSeconds : nil
            speakingChars = newValue.speakingChars > 0 ? newValue.speakingChars : nil
        }
    }
}

struct DeviceData: Codable {
    var dailyCounts: [String: DailyCount]
    /// Coding agent stats, kept apart from `dailyCounts` so keystroke merges never touch them
    /// (optional for backwards compatibility).
    var agentDays: AgentDays?
    /// Whose agent logs `agentDays` came from (`AgentStatsCollector.sourceID`). Device entries
    /// sharing a source read the same logs, so they're merged instead of summed.
    var agentSourceID: String?

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

    mutating func mergeAgentDays(_ other: AgentDays, sourceID: String?) {
        if let sourceID = sourceID { agentSourceID = sourceID }
        guard !other.isEmpty else { return }
        agentDays = mergingAgentDays(agentDays ?? [:], other)
    }

    mutating func pruneOldData(keepingDays: Int = 60) {
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -keepingDays, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffString = formatter.string(from: cutoffDate)

        dailyCounts = dailyCounts.filter { $0.key >= cutoffString }
        agentDays = agentDays?.filter { $0.key >= cutoffString }
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
        case .agents: return totalAgentStats(for: date).charsWritten
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
        case .agents:
            return totalAgentStats(for: date).projectChars
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

    /// Per-agent stats for a date, summed across devices. Keyed by `AgentKind` raw value.
    /// Devices that read the same logs (same `agentSourceID`) are merged first, not summed.
    func agentStats(for date: String) -> [String: AgentDayStats] {
        var bySource: [String: [String: AgentDayStats]] = [:]
        for (deviceID, device) in devices {
            let source = device.agentSourceID ?? deviceID
            for (agent, stats) in device.agentDays?[date] ?? [:] {
                bySource[source, default: [:]][agent] = bySource[source]?[agent].map { $0.merged(with: stats) } ?? stats
            }
        }
        var result: [String: AgentDayStats] = [:]
        for agents in bySource.values {
            for (agent, stats) in agents {
                result[agent] = (result[agent] ?? AgentDayStats()).adding(stats)
            }
        }
        return result
    }

    /// All agents' stats for a date, summed across devices.
    func totalAgentStats(for date: String) -> AgentDayStats {
        agentStats(for: date).values.reduce(AgentDayStats()) { $0.adding($1) }
    }

    /// All agents' stats for the last `days` days ending at `date`.
    func totalAgentStats(forDays days: Int, from date: Date) -> AgentDayStats {
        Self.dateStrings(days: days, from: date).reduce(AgentDayStats()) { $0.adding(totalAgentStats(for: $1)) }
    }

    /// Average characters agents wrote per day, over days they wrote anything (like `averageCount`).
    func averageAgentChars(forLastDays days: Int, from date: Date) -> Double {
        let counts = Self.dateStrings(days: days, from: date).map { totalAgentStats(for: $0).charsWritten }.filter { $0 > 0 }
        return counts.isEmpty ? 0 : Double(counts.reduce(0) { $0.saturatingAdd($1) }) / Double(counts.count)
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
                        // Same count - keep the larger dictation/speed figures from either copy
                        devices[deviceID]?.dailyCounts[date]?.extras = existing.extras.merged(with: otherDailyCount.extras)
                    }
                } else {
                    devices[deviceID]?.dailyCounts[date] = otherDailyCount
                }
            }

            if let otherAgentDays = otherDeviceData.agentDays {
                devices[deviceID]?.mergeAgentDays(otherAgentDays, sourceID: otherDeviceData.agentSourceID)
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
    var extras: DayExtras?         // dictation / speed metrics (optional for backwards compatibility)
}

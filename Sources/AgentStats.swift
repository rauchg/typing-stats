import CryptoKit
import Foundation
import IOKit
import SQLite3

/// Reads coding agents' local session logs (Claude Code, Codex, opencode, fx) and turns them into
/// per-day stats for this device.
///
/// Each scan rebuilds every day from the logs instead of incrementing, so running it twice can't
/// double-count. Files that haven't changed since the last scan reuse their parsed events.
/// The log formats are undocumented and change between versions, so parsers skip anything they
/// don't recognize. Only counts are kept: prompt and code text is measured, never stored.
final class AgentStatsCollector {
    /// How far back to read; matches how long the sync file keeps days.
    static let keepingDays = 60

    private let queue = DispatchQueue(label: "com.typing-stats.agents", qos: .utility)
    private let home: URL
    /// Parsed events per source, reused while the source is unchanged. Only touched on `queue`.
    private var cache: [String: CachedSource] = [:]

    private struct CachedSource {
        let signature: [FileSignature]
        let events: [AgentEvent]
    }

    private struct FileSignature: Equatable {
        let size: Int
        let modified: Date
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Identifies whose logs these are: this Mac and user account. Installs reading the same logs
    /// (dev and release builds, or a reinstall with a new device ID) share it, so their agent stats
    /// are deduplicated instead of summed. Hashed so the hardware UUID itself isn't synced.
    static let sourceID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let hardware = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        // Without a hardware UUID, fall back to per-install (stats would be summed, not deduplicated).
        let seed = "\(hardware ?? UUID().uuidString):\(NSUserName())"
        return SHA256.hash(data: Data(seed.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    /// Scans in the background and calls `completion` on the main queue.
    func collect(completion: @escaping (AgentDays) -> Void) {
        queue.async {
            let result = self.scan()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous scan. Not thread-safe; `collect` runs it on the collector's queue.
    func scan() -> AgentDays {
        let cutoff = Date().addingTimeInterval(-Double(Self.keepingDays) * 86_400)
        var sources: [(id: String, signature: [FileSignature], parse: () -> [AgentEvent])] = []

        for url in claudeCodeFiles() { sources.append(jsonlSource(url, cutoff: cutoff, parse: ClaudeCodeParser.parse)) }
        for url in codexFiles() { sources.append(jsonlSource(url, cutoff: cutoff, parse: CodexParser.parse)) }
        for url in fxFiles() { sources.append(jsonlSource(url, cutoff: cutoff, parse: FxParser.parse)) }
        let opencodeDB = home.appendingPathComponent(".local/share/opencode/opencode.db")
        if let signature = signature(of: opencodeDB) {
            // WAL mode: recent writes live in the -wal file until checkpointed.
            let wal = self.signature(of: URL(fileURLWithPath: opencodeDB.path + "-wal"))
            sources.append((opencodeDB.path, [signature] + (wal.map { [$0] } ?? []),
                            { OpencodeParser.parse(dbPath: opencodeDB.path, since: cutoff) }))
        }

        var fresh: [String: CachedSource] = [:]
        for source in sources where !source.signature.isEmpty {
            if let cached = cache[source.id], cached.signature == source.signature {
                fresh[source.id] = cached
            } else {
                fresh[source.id] = CachedSource(signature: source.signature, events: source.parse())
            }
        }
        cache = fresh  // drops sources that disappeared

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffDay = formatter.string(from: cutoff)

        var days = AgentDays()
        var seen = Set<String>()
        // Sorted so that when two files share an event (a resumed session copying history),
        // the same copy wins every scan.
        for id in fresh.keys.sorted() {
            for event in fresh[id]!.events {
                if let key = event.key, !seen.insert(key).inserted { continue }
                let day = formatter.string(from: event.time)
                guard day >= cutoffDay else { continue }
                var stats = event.stats
                if let project = event.project, stats.charsWritten > 0 {
                    stats.projectChars[project] = stats.charsWritten
                }
                let agent = event.agent.rawValue
                days[day, default: [:]][agent] = (days[day]?[agent] ?? AgentDayStats()).adding(stats)
            }
        }
        return days
    }

    // MARK: - Sources

    private func jsonlSource(_ url: URL, cutoff: Date, parse: @escaping (Data) -> [AgentEvent])
        -> (id: String, signature: [FileSignature], parse: () -> [AgentEvent]) {
        // Files untouched since the cutoff can only hold days we no longer keep.
        guard let signature = signature(of: url), signature.modified >= cutoff else { return (url.path, [], { [] }) }
        return (url.path, [signature], {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
            return parse(data)
        })
    }

    private func signature(of url: URL) -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return FileSignature(size: size, modified: modified)
    }

    private func children(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    /// ~/.claude/projects/<project>/<session>.jsonl, plus <session>/subagents/*.jsonl.
    private func claudeCodeFiles() -> [URL] {
        var files: [URL] = []
        for project in children(of: home.appendingPathComponent(".claude/projects")) {
            for entry in children(of: project) {
                if entry.pathExtension == "jsonl" {
                    files.append(entry)
                } else {
                    files += children(of: entry.appendingPathComponent("subagents")).filter { $0.pathExtension == "jsonl" }
                }
            }
        }
        return files
    }

    /// ~/.codex/sessions/YYYY/MM/DD/*.jsonl and ~/.codex/archived_sessions/*.jsonl.
    private func codexFiles() -> [URL] {
        var files: [URL] = []
        for root in [".codex/sessions", ".codex/archived_sessions"] {
            let enumerator = FileManager.default.enumerator(at: home.appendingPathComponent(root), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "jsonl" { files.append(url) }
            }
        }
        return files
    }

    /// ~/.fx/sessions/v2/<session>/log.jsonl
    private func fxFiles() -> [URL] {
        children(of: home.appendingPathComponent(".fx/sessions/v2"))
            .map { $0.appendingPathComponent("log.jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Events

/// One countable thing from a log: an API response's tokens, an edit, a prompt, a finished turn…
struct AgentEvent {
    let agent: AgentKind
    let time: Date
    /// Workspace folder name, used for the per-project breakdown.
    let project: String?
    /// Events sharing a key are counted once across all files (e.g. a message copied into a
    /// resumed session's file).
    let key: String?
    let stats: AgentDayStats
}

// MARK: - Parsing Helpers

private enum LogParsing {
    /// Calls `body` with each newline-terminated line. A trailing partial line (one the agent is
    /// still writing) is skipped and picked up by the next scan.
    static func forEachLine(in data: Data, _ body: (UnsafeRawBufferPointer) -> Void) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count,
                  let newline = memchr(base + start, 0x0A, buffer.count - start) {
                let end = base.distance(to: UnsafeRawPointer(newline))
                if end > start { body(UnsafeRawBufferPointer(rebasing: buffer[start..<end])) }
                start = end + 1
            }
        }
    }

    /// Cheap substring check, used to skip lines before paying for JSON parsing.
    static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress else { return false }
        return needle.withUnsafeBytes { n in memmem(base, line.count, n.baseAddress, n.count) != nil }
    }

    static func needle(_ s: String) -> [UInt8] { Array(s.utf8) }

    static func json(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes: base, count: line.count)) as? [String: Any]
    }

    static func json(_ string: String) -> [String: Any]? {
        string.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func int(_ value: Any?) -> Int {
        guard let n = value as? NSNumber, n.doubleValue.isFinite else { return 0 }
        return max(0, n.intValue)
    }

    static func double(_ value: Any?) -> Double {
        guard let n = value as? NSNumber, n.doubleValue.isFinite else { return 0 }
        return max(0, n.doubleValue)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func date(iso8601 value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }

    static func date(milliseconds value: Any?) -> Date? {
        let ms = double(value)
        return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
    }

    /// Folder name of a working directory ("/Users/me/Developer/api" -> "api").
    static func project(_ value: Any?) -> String? {
        guard var path = value as? String, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.isFileURL { path = url.path }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Length in UTF-16 units, the same unit dictation uses.
    static func chars(_ s: String) -> Int { (s as NSString).length }

    static func lineCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        let newlines = s.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return s.hasSuffix("\n") ? newlines : newlines + 1
    }

    /// Stats for text written as a whole new file.
    static func written(_ content: String) -> AgentDayStats {
        var s = AgentDayStats()
        s.charsWritten = chars(content)
        s.linesAdded = lineCount(content)
        return s
    }

    /// Stats for diff lines prefixed with "+" / "-" (Claude Code hunks, Codex/opencode patches).
    /// Each added line counts its newline. Lines starting "+++" / "---" are real changes here
    /// (adding `++i;`, removing a `-- comment`); pass `unifiedDiff` to skip "--- a" / "+++ b" file
    /// header pairs instead. apply_patch's "*** …" lines never start with +/-.
    static func patch<S: Collection>(lines: S, unifiedDiff: Bool = false) -> AgentDayStats where S.Element: StringProtocol {
        var s = AgentDayStats()
        var previous: S.Element?
        for line in lines {
            defer { previous = line }
            if unifiedDiff, line.hasPrefix("+++ "), previous?.hasPrefix("--- ") == true {
                s.linesRemoved -= 1  // the "--- " line before it was the other half of the header
                continue
            }
            if line.hasPrefix("+") {
                s.linesAdded += 1
                s.charsWritten += chars(String(line.dropFirst())) + 1
            } else if line.hasPrefix("-") {
                s.linesRemoved += 1
            }
        }
        return s
    }

    static func patch(_ text: String, unifiedDiff: Bool = false) -> AgentDayStats {
        patch(lines: text.split(separator: "\n", omittingEmptySubsequences: false), unifiedDiff: unifiedDiff)
    }

    /// Stats for replacing `old` with `new`. Lines both share at the start and end are context
    /// (opencode's edit tool includes some so the match is unique) and don't count as changed.
    static func replacement(old: String, new: String) -> AgentDayStats {
        var oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var newLines = new.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let o = oldLines.first, let n = newLines.first, o == n {
            oldLines = oldLines.dropFirst()
            newLines = newLines.dropFirst()
        }
        while let o = oldLines.last, let n = newLines.last, o == n {
            oldLines = oldLines.dropLast()
            newLines = newLines.dropLast()
        }
        var s = AgentDayStats()
        s.linesAdded = newLines.count
        s.linesRemoved = oldLines.count
        s.charsWritten = newLines.reduce(0) { $0 + chars(String($1)) + 1 }
        return s
    }

    /// Prompt text from a string or a list of `{type: "text", text: …}` blocks.
    static func promptText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static func prompt(_ text: String) -> AgentDayStats {
        var s = AgentDayStats()
        s.prompts = 1
        s.promptChars = chars(text)
        return s
    }
}

// MARK: - Claude Code

/// ~/.claude/projects/*/*.jsonl: one JSON record per line.
/// - assistant: `message.usage` per API response. One response is split across several records
///   sharing `message.id`, each with the usage so far, so they're collapsed to the largest.
/// - user with `toolUseResult.structuredPatch` (Edit/Write results) or `content` (new files).
/// - user with `origin.kind == "human"`: a prompt you sent.
/// - system `turn_duration`: how long a turn took.
private enum ClaudeCodeParser {
    private static let assistantNeedle = LogParsing.needle("\"type\":\"assistant\"")
    private static let editNeedle = LogParsing.needle("\"structuredPatch\"")
    private static let promptNeedle = LogParsing.needle("\"origin\":{\"kind\":\"human\"")
    private static let turnNeedle = LogParsing.needle("\"subtype\":\"turn_duration\"")

    static func parse(_ data: Data) -> [AgentEvent] {
        var events: [AgentEvent] = []
        var responses: [String: AgentEvent] = [:]

        func event(_ r: [String: Any], _ time: Date, _ key: String?, _ stats: AgentDayStats) -> AgentEvent {
            AgentEvent(agent: .claudeCode, time: time, project: LogParsing.project(r["cwd"]), key: key, stats: stats)
        }

        LogParsing.forEachLine(in: data) { line in
            // Most lines are large tool outputs we don't need; skip them unparsed.
            guard LogParsing.contains(line, assistantNeedle) || LogParsing.contains(line, editNeedle)
                    || LogParsing.contains(line, promptNeedle) || LogParsing.contains(line, turnNeedle),
                  let r = LogParsing.json(line),
                  let time = LogParsing.date(iso8601: r["timestamp"]) else { return }

            switch r["type"] as? String {
            case "assistant":
                guard let message = r["message"] as? [String: Any] else { return }
                if let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] {
                    var s = AgentDayStats()
                    s.inputTokens = LogParsing.int(usage["input_tokens"])
                    s.outputTokens = LogParsing.int(usage["output_tokens"])
                    s.cacheReadTokens = LogParsing.int(usage["cache_read_input_tokens"])
                    s.cacheWriteTokens = LogParsing.int(usage["cache_creation_input_tokens"])
                    if s.outputTokens >= (responses[id]?.stats.outputTokens ?? 0) {
                        responses[id] = event(r, time, "claude-code:response:\(id)", s)
                    }
                }
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    var s = AgentDayStats()
                    s.toolCalls = 1
                    events.append(event(r, time, (block["id"] as? String).map { "claude-code:tool:\($0)" }, s))
                }

            case "user":
                let message = r["message"] as? [String: Any]
                if let result = r["toolUseResult"] as? [String: Any] {
                    let s: AgentDayStats
                    if let hunks = result["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
                        s = LogParsing.patch(lines: hunks.flatMap { $0["lines"] as? [String] ?? [] })
                    } else if result["type"] as? String == "create", let content = result["content"] as? String {
                        s = LogParsing.written(content)
                    } else {
                        return
                    }
                    let toolUseID = (message?["content"] as? [[String: Any]])?.first?["tool_use_id"] as? String
                    let key = (toolUseID ?? r["uuid"] as? String).map { "claude-code:edit:\($0)" }
                    events.append(event(r, time, key, s))
                } else if (r["origin"] as? [String: Any])?["kind"] as? String == "human",
                          r["isMeta"] as? Bool != true,
                          let text = LogParsing.promptText(message?["content"]) {
                    events.append(event(r, time, (r["uuid"] as? String).map { "claude-code:prompt:\($0)" }, LogParsing.prompt(text)))
                }

            case "system":
                guard r["subtype"] as? String == "turn_duration" else { return }
                var s = AgentDayStats()
                s.activeSeconds = LogParsing.double(r["durationMs"]) / 1000
                events.append(event(r, time, (r["uuid"] as? String).map { "claude-code:turn:\($0)" }, s))

            default:
                break
            }
        }
        return events + responses.values
    }
}

// MARK: - Codex

/// ~/.codex/sessions/YYYY/MM/DD/*.jsonl: `{timestamp, type, payload}` per line.
/// - `token_usage_record`: usage per model response (`input_tokens` includes cached tokens).
///   Older files only have cumulative `event_msg/token_count` totals, used as a fallback.
/// - Prompts you sent: `event_msg/user_message` (CLI), or in Codex Desktop an `item_completed`
///   `UserMessage` in a turn you started (`task_started.turn_attribution.turn_trigger`). Other
///   turns' user messages are internal (guardian reviews, subagents).
/// - `event_msg/task_complete`: a turn's duration.
/// - `response_item` function/custom tool calls; `apply_patch` and `FileChange` items are edits.
/// - `session_meta` / `turn_context` carry the working directory.
private enum CodexParser {
    private static let needles = ["\"type\":\"session_meta\"", "\"type\":\"turn_context\"",
                                  "\"type\":\"token_usage_record\"", "\"type\":\"token_count\"",
                                  "\"type\":\"user_message\"", "\"type\":\"task_complete\"",
                                  "\"type\":\"task_started\"", "\"type\":\"UserMessage\"",
                                  "\"type\":\"function_call\"", "\"type\":\"custom_tool_call\"",
                                  "\"type\":\"FileChange\"", "\"type\":\"fileChange\""].map(LogParsing.needle)

    static func parse(_ data: Data) -> [AgentEvent] {
        var events: [AgentEvent] = []
        var cwd: String?
        var sawUsageRecords = false
        var cumulativeEvents: [AgentEvent] = []
        var lastTotal = AgentDayStats()
        var fileChangeEvents: [AgentEvent] = []
        var applyPatchEvents: [AgentEvent] = []
        var userTurns = Set<String>()

        func event(_ time: Date, _ key: String?, _ stats: AgentDayStats) -> AgentEvent {
            AgentEvent(agent: .codex, time: time, project: LogParsing.project(cwd), key: key, stats: stats)
        }

        func tokens(_ usage: [String: Any]) -> AgentDayStats {
            var s = AgentDayStats()
            let cached = LogParsing.int(usage["cached_input_tokens"])
            let cacheWrite = LogParsing.int(usage["cache_write_input_tokens"])
            s.inputTokens = max(0, LogParsing.int(usage["input_tokens"]) - cached - cacheWrite)
            s.cacheReadTokens = cached
            s.cacheWriteTokens = cacheWrite
            s.outputTokens = LogParsing.int(usage["output_tokens"])
            return s
        }

        LogParsing.forEachLine(in: data) { line in
            guard needles.contains(where: { LogParsing.contains(line, $0) }),
                  let r = LogParsing.json(line),
                  let payload = r["payload"] as? [String: Any],
                  let time = LogParsing.date(iso8601: r["timestamp"]) else { return }

            switch r["type"] as? String {
            case "session_meta", "turn_context":
                if let dir = payload["cwd"] as? String { cwd = dir }

            case "token_usage_record":
                guard let usage = payload["usage"] as? [String: Any] else { return }
                sawUsageRecords = true
                events.append(event(time, (payload["response_id"] as? String).map { "codex:response:\($0)" }, tokens(usage)))

            case "event_msg":
                switch payload["type"] as? String {
                case "token_count":
                    guard let total = ((payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any]).map(tokens) else { return }
                    var delta = AgentDayStats()
                    delta.inputTokens = max(0, total.inputTokens - lastTotal.inputTokens)
                    delta.cacheReadTokens = max(0, total.cacheReadTokens - lastTotal.cacheReadTokens)
                    delta.cacheWriteTokens = max(0, total.cacheWriteTokens - lastTotal.cacheWriteTokens)
                    delta.outputTokens = max(0, total.outputTokens - lastTotal.outputTokens)
                    lastTotal = total
                    if delta.hasActivity { cumulativeEvents.append(event(time, nil, delta)) }
                case "user_message":
                    guard let text = payload["message"] as? String else { return }
                    events.append(event(time, nil, LogParsing.prompt(text)))
                case "task_started":
                    let trigger = (payload["turn_attribution"] as? [String: Any])?["turn_trigger"] as? String
                    if let turn = payload["turn_id"] as? String,
                       ["composer", "edit_user_message", "send_user_message_async_question"].contains(trigger ?? "") {
                        userTurns.insert(turn)
                    }
                case "task_complete":
                    var s = AgentDayStats()
                    s.activeSeconds = LogParsing.double(payload["duration_ms"]) / 1000
                    events.append(event(time, (payload["turn_id"] as? String).map { "codex:turn:\($0)" }, s))
                case "item_completed":
                    guard let item = payload["item"] as? [String: Any] else { return }
                    if item["type"] as? String == "UserMessage" {
                        guard userTurns.contains(payload["turn_id"] as? String ?? ""),
                              let text = LogParsing.promptText(item["content"]) else { return }
                        let key = (item["id"] as? String).map { "codex:prompt:\(payload["thread_id"] as? String ?? ""):\($0)" }
                        events.append(event(time, key, LogParsing.prompt(text)))
                        return
                    }
                    guard ["FileChange", "fileChange"].contains(item["type"] as? String ?? "") else { return }
                    var s = AgentDayStats()
                    for change in item["changes"] as? [[String: Any]] ?? [] {
                        let diff = change["diff"] as? String ?? ""
                        let kind = (change["kind"] as? [String: Any])?["type"] as? String ?? change["kind"] as? String
                        switch kind {
                        case "add": s = s.adding(LogParsing.written(diff))
                        case "delete": s.linesRemoved += LogParsing.lineCount(diff)
                        default: s = s.adding(LogParsing.patch(diff, unifiedDiff: true))
                        }
                    }
                    fileChangeEvents.append(event(time, (item["id"] as? String).map { "codex:edit:\($0)" }, s))
                default:
                    break
                }

            case "response_item":
                guard ["function_call", "custom_tool_call"].contains(payload["type"] as? String ?? "") else { return }
                let callKey = (payload["call_id"] as? String).map { "codex:tool:\($0)" }
                var s = AgentDayStats()
                s.toolCalls = 1
                events.append(event(time, callKey, s))
                if payload["name"] as? String == "apply_patch" {
                    // custom_tool_call carries the patch as `input`; function_call as JSON `arguments.input`.
                    let patch = payload["input"] as? String
                        ?? (payload["arguments"] as? String).flatMap(LogParsing.json)?["input"] as? String
                    if let patch = patch {
                        applyPatchEvents.append(event(time, callKey.map { "\($0):patch" }, LogParsing.patch(patch)))
                    }
                }

            default:
                break
            }
        }
        // Prefer per-response usage; prefer applied FileChange results over requested patches.
        // Using both of either pair would count the same tokens/edits twice.
        return events
            + (sawUsageRecords ? [] : cumulativeEvents)
            + (fileChangeEvents.isEmpty ? applyPatchEvents : fileChangeEvents)
    }
}

// MARK: - fx

/// ~/.fx/sessions/v2/<session>/log.jsonl: `{seq, ts (ms), kind, type?, data}` per line.
/// - `session_created` has the workspace. `item/user` is a prompt.
/// - `item/tool_call` is a tool call; `item/tool_result` with `committed_file_presentation` is an
///   applied edit, with added lines and totals.
/// - `item/turn_end` has the turn's duration and output tokens. fx's input counts are estimates
///   (`input_exact: false`), so they're used only when marked exact.
private enum FxParser {
    static func parse(_ data: Data) -> [AgentEvent] {
        var events: [AgentEvent] = []
        var workspace: String?
        var toolCalls = Set<String>()

        LogParsing.forEachLine(in: data) { line in
            guard let r = LogParsing.json(line), let time = LogParsing.date(milliseconds: r["ts"]) else { return }
            if r["kind"] as? String == "session_created" {
                workspace = r["workspace"] as? String
                return
            }
            guard r["kind"] as? String == "item", let d = r["data"] as? [String: Any] else { return }

            var s = AgentDayStats()
            switch r["type"] as? String {
            case "user":
                guard let text = d["text"] as? String else { return }
                s = LogParsing.prompt(text)
            case "tool_call":
                if let id = d["call_id"] as? String, !toolCalls.insert(id).inserted { return }
                s.toolCalls = 1
            case "tool_result":
                guard d["status"] as? String == "success",
                      let file = d["committed_file_presentation"] as? [String: Any] else { return }
                let lines = file["lines"] as? [[String: Any]] ?? []
                let added = lines.filter { $0["kind"] as? String == "addition" }.compactMap { $0["text"] as? String }
                if file["kind"] as? String == "added", let content = file["after_content"] as? String {
                    s.charsWritten = LogParsing.chars(content)
                } else {
                    s.charsWritten = added.reduce(0) { $0 + LogParsing.chars($1) + 1 }
                }
                s.linesAdded = file["additions"].map(LogParsing.int) ?? added.count
                s.linesRemoved = LogParsing.int(file["deletions"])
            case "turn_end":
                guard let summary = d["turn_summary"] as? [String: Any] else { return }
                s.activeSeconds = LogParsing.double(summary["turn_duration_ms"]) / 1000
                if let progress = summary["token_progress"] as? [String: Any] {
                    if progress["output_exact"] as? Bool == true { s.outputTokens = LogParsing.int(progress["output_tokens"]) }
                    if progress["input_exact"] as? Bool == true { s.inputTokens = LogParsing.int(progress["input_tokens"]) }
                }
            default:
                return
            }
            events.append(AgentEvent(agent: .fx, time: time, project: LogParsing.project(workspace), key: nil, stats: s))
        }
        return events
    }
}

// MARK: - opencode

/// ~/.local/share/opencode/opencode.db (SQLite, WAL). `session_message.data` is JSON:
/// - assistant: `tokens {input, output, reasoning, cache {read, write}}`, `cost`, `time`, and
///   `content` parts; `tool` parts named edit/write/patch/apply_patch are edits.
/// - user: `text` is the prompt.
/// `session_v2.directory` is the workspace.
private enum OpencodeParser {
    static func parse(dbPath: String, since: Date) -> [AgentEvent] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let sql = """
            SELECT m.id, m.type, m.time_created, m.data, s.directory
            FROM session_message m LEFT JOIN session_v2 s ON s.id = m.session_id
            WHERE m.time_created >= ? AND m.type IN ('user', 'assistant')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            // Schema we don't know (older or newer opencode).
            print("opencode: unsupported database schema: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        var events: [AgentEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(0), let type = text(1), let d = text(3).flatMap(LogParsing.json),
                  let time = LogParsing.date(milliseconds: NSNumber(value: sqlite3_column_int64(statement, 2))) else { continue }

            let s: AgentDayStats
            if type == "user" {
                guard let prompt = d["text"] as? String else { continue }
                s = LogParsing.prompt(prompt)
            } else {
                s = assistantStats(d)
            }
            events.append(AgentEvent(agent: .opencode, time: time, project: LogParsing.project(text(4)),
                                     key: "opencode:\(id)", stats: s))
        }
        return events
    }

    private static func assistantStats(_ d: [String: Any]) -> AgentDayStats {
        var s = AgentDayStats()
        if let tokens = d["tokens"] as? [String: Any] {
            let cache = tokens["cache"] as? [String: Any]
            s.inputTokens = LogParsing.int(tokens["input"])
            s.outputTokens = LogParsing.int(tokens["output"]) + LogParsing.int(tokens["reasoning"])
            s.cacheReadTokens = LogParsing.int(cache?["read"])
            s.cacheWriteTokens = LogParsing.int(cache?["write"])
        }
        s.costUSD = LogParsing.double(d["cost"])
        if let time = d["time"] as? [String: Any] {
            let created = LogParsing.double(time["created"]), completed = LogParsing.double(time["completed"])
            if created > 0, completed > created { s.activeSeconds = (completed - created) / 1000 }
        }
        for part in d["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "tool" {
            s.toolCalls += 1
            guard let state = part["state"] as? [String: Any], state["status"] as? String == "completed",
                  let input = state["input"] as? [String: Any] else { continue }
            switch part["name"] as? String {
            case "edit":
                s = s.adding(LogParsing.replacement(old: input["oldString"] as? String ?? "",
                                                    new: input["newString"] as? String ?? ""))
            case "write":
                // The log doesn't keep the previous content, so an overwrite counts as the whole file.
                s = s.adding(LogParsing.written(input["content"] as? String ?? ""))
            case "patch", "apply_patch":
                s = s.adding(LogParsing.patch(input["patchText"] as? String ?? ""))
            default:
                break
            }
        }
        return s
    }
}

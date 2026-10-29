import Cocoa
import CoreAudio

// MARK: - Dictation Sources

/// Identifies dictation apps (Aqua Voice, Willow, Wispr Flow, …) that insert transcripts by
/// putting text on the clipboard and posting a synthetic Cmd+V.
enum DictationSources {
    /// Bundle IDs of the *outermost* app bundle. Helper processes are resolved to their
    /// containing app (e.g. Aqua's `AquaMacOSBridge.app` → `com.electron.aqua-voice`).
    /// Verified with the probe: Aqua Voice. Verified from the binary: Willow Voice.
    /// The rest are best-effort and can be extended with:
    ///   defaults write com.typing-stats.app additionalDictationBundleIDs -array com.example.app
    static let builtIn: Set<String> = [
        "com.electron.aqua-voice",
        "aquavoice.macOSBridge",
        "com.seewillow.WillowMac",
        "com.electron.wispr-flow",
        "com.superduper.superwhisper",
        "com.goodsnooze.MacWhisper",
        "com.prakashjoshipax.VoiceInk",
    ]

    static var allowlist: Set<String> {
        let extra = UserDefaults.standard.stringArray(forKey: "additionalDictationBundleIDs") ?? []
        return builtIn.union(extra)
    }

    /// Bundle ID of the outermost `.app` containing the process's executable,
    /// falling back to the process's own bundle ID.
    /// Deliberately uncached: PIDs get reused, and a stale cache entry would let an unrelated
    /// process inherit a dictation app's identity. `proc_pidpath` is cheap and this only runs
    /// for synthetic key events and audio process-list changes.
    static func owningAppBundleID(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var result: String?
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let components = String(cString: buf).split(separator: "/", omittingEmptySubsequences: false)
            if let idx = components.firstIndex(where: { $0.hasSuffix(".app") }) {
                let appPath = components[...idx].joined(separator: "/")
                result = Bundle(path: appPath)?.bundleIdentifier
            }
        }
        if result == nil {
            result = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        return result
    }

    /// Returns the dictation app's bundle ID if `pid` belongs to an allowlisted dictation app.
    static func dictationApp(forPID pid: pid_t) -> String? {
        let list = allowlist
        if let owner = owningAppBundleID(pid: pid), list.contains(owner) { return owner }
        if let own = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, list.contains(own) {
            return owningAppBundleID(pid: pid) ?? own
        }
        return nil
    }
}

// MARK: - Mic Session Tracker

/// Tracks when dictation apps hold the microphone open, using CoreAudio's per-process
/// input state (macOS 14.2+). An utterance's "speaking session" is the span from the
/// app starting audio input to it stopping, which is then paired with the next paste.
final class MicSessionTracker {
    private struct Interval { let start: Date; let end: Date }

    /// Longest session we'll attribute to one paste (guards against always-on / hands-free modes).
    private let maxSessionSeconds: TimeInterval = 15 * 60
    /// How long after the mic closes a paste can still claim the session (transcription latency).
    private let claimWindow: TimeInterval = 120
    /// Follow-up pastes (multi-part inserts) within this window count as timed with no extra time.
    private let followUpWindow: TimeInterval = 15

    private var runningProcessObjects: [AudioObjectID: String] = [:]  // process object -> app ID
    private var activeStart: [String: Date] = [:]                     // app ID -> mic-open time
    private var finished: [String: [Interval]] = [:]
    private var lastClaim: [String: Date] = [:]
    /// Per-process IsRunningInput listeners, kept so they can be removed when the process goes away.
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listenedObjects: Set<AudioObjectID> { Set(listeners.keys) }
    private(set) var isSupported = false

    deinit {
        guard #available(macOS 14.2, *) else { return }
        for (obj, block) in listeners {
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(obj, &addr, DispatchQueue.main, block)
        }
    }

    func start() {
        guard #available(macOS 14.2, *) else { return }
        isSupported = true
        var listAddr = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.refreshProcessList()
        }
        refreshProcessList()
    }

    /// Seconds of speaking to attribute to a paste from `appID`.
    /// - Returns: seconds (> 0) for a fresh session, 0 for a follow-up paste of the same session,
    ///   or nil when the paste can't be timed.
    func claimSession(for appID: String, at now: Date = Date()) -> Double? {
        var seconds: Double = 0
        let recent = (finished[appID] ?? []).filter { now.timeIntervalSince($0.end) <= claimWindow }
        seconds += recent.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        finished[appID] = []
        if let start = activeStart[appID] {
            // Mic still open (streaming / continuous mode): claim up to now, restart the clock.
            seconds += now.timeIntervalSince(start)
            activeStart[appID] = now
        }
        if seconds > 0 {
            lastClaim[appID] = now
            return seconds <= maxSessionSeconds ? seconds : nil
        }
        if let last = lastClaim[appID], now.timeIntervalSince(last) <= followUpWindow {
            return 0
        }
        return nil
    }

    // MARK: CoreAudio plumbing

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func refreshProcessList() {
        guard #available(macOS 14.2, *) else { return }
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return }

        let current = Set(ids)
        // Processes that went away while recording count as having stopped.
        for gone in listenedObjects.subtracting(current) {
            if let block = listeners.removeValue(forKey: gone) {
                var runAddr = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(gone, &runAddr, DispatchQueue.main, block)
            }
            setRunning(false, object: gone)
        }
        for obj in current where !listenedObjects.contains(obj) {
            guard let pid = processPID(obj), let app = DictationSources.dictationApp(forPID: pid) else { continue }
            var runAddr = Self.address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.updateRunning(object: obj, app: app)
            }
            guard AudioObjectAddPropertyListenerBlock(obj, &runAddr, DispatchQueue.main, block) == noErr else { continue }
            listeners[obj] = block
            updateRunning(object: obj, app: app)
        }
    }

    private func updateRunning(object: AudioObjectID, app: String) {
        guard #available(macOS 14.2, *) else { return }
        var addr = Self.address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let running = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr && value != 0
        if running { runningProcessObjects[object] = app }
        setRunning(running, object: object)
    }

    private func setRunning(_ running: Bool, object: AudioObjectID) {
        guard let app = runningProcessObjects[object] else { return }
        let now = Date()
        if running {
            if activeStart[app] == nil { activeStart[app] = now }
            return
        }
        runningProcessObjects[object] = nil
        // Only close the session when no other process of the same app is still recording.
        guard !runningProcessObjects.values.contains(app), let start = activeStart.removeValue(forKey: app) else { return }
        var list = (finished[app] ?? []).filter { now.timeIntervalSince($0.end) <= claimWindow }
        list.append(Interval(start: start, end: now))
        finished[app] = list
    }

    private func processPID(_ obj: AudioObjectID) -> pid_t? {
        guard #available(macOS 14.2, *) else { return nil }
        var addr = Self.address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr ? pid : nil
    }
}

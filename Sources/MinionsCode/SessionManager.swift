import Foundation
import CoreServices

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Snapshot of a parsed JSONL: sticky cache so we don't re-parse unchanged files every poll tick.
struct JsonlCache: Sendable {
    var fingerprint: String  // "size:mtime" combo
    var usage: TokenUsage
    var model: String?
    var aiTitle: String?
    var cwd: String?
}

/// FSEventStream callback — must be a free function (or pure C closure) so
/// it carries no actor isolation. Calling it from the FSEvents dispatch
/// queue would otherwise trip Swift's MainActor assertion. We hop to the
/// main queue here, then bounce into MainActor land via `Task`.
private func fsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let unmanaged = Unmanaged<SessionManager>.fromOpaque(info)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            unmanaged.takeUnretainedValue().handleFSEvents()
        }
    }
}

@MainActor
@Observable
final class SessionManager {
    static let shared = SessionManager()

    var sessions: [SessionInfo] = []
    var selectedSessionId: String?
    /// True while the deep history scan is running. Sidebar shows a "thinking"
    /// indicator so the user knows results will appear progressively.
    var isLoadingHistory: Bool = false
    /// Slow safety-net timer — fires every 60s in case FSEvents drops something
    /// (sleep, network volume, etc.). Real refresh is event-driven via the
    /// FSEventStream below.
    private var safetyTimer: Timer?
    private var fsStream: FSEventStreamRef?
    /// Debounce token: the most recent FS event schedules this; earlier ones
    /// get cancelled. Without it a `claude` mid-stream would fire scan() many
    /// times per second.
    private var debounceTask: Task<Void, Never>?
    private var customNames: [String: String] = [:]
    nonisolated(unsafe) private static var cache: [String: JsonlCache] = [:]
    nonisolated(unsafe) private static let cacheLock = NSLock()

    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private let namesFile: URL

    init() {
        namesFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".minionscode")
            .appendingPathComponent("session-names.json")
        loadNames()
    }

    var selectedSession: SessionInfo? {
        sessions.first { $0.id == selectedSessionId }
    }

    var totalCost: Double { sessions.reduce(0) { $0 + $1.cost } }
    var activeSessions: Int { sessions.filter(\.isAlive).count }

    func startPolling(interval: TimeInterval = 60) {
        scan()
        startFSWatcher()
        // Slow heartbeat fallback — FSEvents covers ~all real updates, but a
        // 60s safety net catches edge cases (volume unmount/mount, system
        // sleep, the rare missed event) without burning CPU like the old 5s
        // poll did.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan(historyDays: nil) }
        }
    }

    /// Watches `~/.claude/projects/` (where session JSONLs live) and
    /// `~/.claude/sessions/` (live PID files). Any write inside debounces
    /// a single scan() ~250ms later — much faster than the old 5s poll, and
    /// no CPU when nothing's happening.
    private func startFSWatcher() {
        if fsStream != nil { return }
        let projects = claudeDir.appendingPathComponent("projects").path
        let sessions = claudeDir.appendingPathComponent("sessions").path
        let paths = [projects, sessions] as CFArray

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsCallback,
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,  // 200ms latency — coalesces bursts of writes
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .global(qos: .utility))
        FSEventStreamStart(stream)
        self.fsStream = stream
    }

    /// Called on the main actor whenever FSEvents fires. Debounces — a fresh
    /// burst of events restarts the timer, so a flurry of writes from a live
    /// claude session triggers exactly one scan() at the end.
    fileprivate func handleFSEvents() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            self.scan(historyDays: nil)
        }
    }


    /// Two-phase scan, both async:
    /// - Phase 1 (background, fast): live PIDs + stat-only recent JSONLs.
    ///   Posts results to main as soon as they're ready (~100-300ms).
    /// - Phase 2 (background, slower): full history within horizon.
    ///   Merged when ready, marked complete via isLoadingHistory.
    func scan(historyDays: Int? = nil) {
        let snapshotNames = customNames
        let claudeDir = self.claudeDir
        let days = historyDays ?? AppSettings.shared.historyHorizonDays

        isLoadingHistory = true

        Task.detached(priority: .userInitiated) {
            // Phase 1
            let livesOnly = Self.scanLiveOnly(claudeDir: claudeDir, customNames: snapshotNames)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                var working = self.sessions.filter { !$0.isAlive }
                let liveIds = Set(livesOnly.map(\.id))
                working.removeAll { liveIds.contains($0.id) }
                working.append(contentsOf: livesOnly)
                self.sessions = Self.applySort(working)
                NotificationManager.shared.observe(sessions: self.sessions)
            }

            // Phase 2
            let history = Self.scanHistory(claudeDir: claudeDir, customNames: snapshotNames, days: days)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                let historyById = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
                let liveSet = Set(self.sessions.filter(\.isAlive).map(\.id))
                var merged: [SessionInfo] = []
                // Enrich alive sessions with parsed model/usage from their JSONL.
                // Phase 1 stat-only walks leave model=nil; Phase 2 fills it in.
                for live in self.sessions where live.isAlive {
                    if let h = historyById[live.id] {
                        merged.append(SessionInfo(
                            id: live.id, pid: live.pid, sessionId: live.sessionId,
                            name: live.name == Self.shortPathStatic(live.cwd) ? h.name : live.name,
                            cwd: live.cwd, status: live.status, startedAt: live.startedAt,
                            lastActivityAt: live.lastActivityAt ?? h.lastActivityAt,
                            version: live.version,
                            model: h.model ?? live.model,
                            usage: h.usage,
                            cost: h.cost,
                            cacheHitRate: h.cacheHitRate,
                            isAlive: true
                        ))
                    } else {
                        merged.append(live)
                    }
                }
                for entry in history where !liveSet.contains(entry.id) {
                    merged.append(entry)
                }
                self.sessions = Self.applySort(merged)
                self.isLoadingHistory = false
                NotificationManager.shared.observe(sessions: self.sessions)
            }
        }
    }

    nonisolated static func applySort(_ s: [SessionInfo]) -> [SessionInfo] {
        s.sorted {
            if $0.isAlive != $1.isAlive { return $0.isAlive && !$1.isAlive }
            if $0.isRecentlyActive != $1.isRecentlyActive { return $0.isRecentlyActive && !$1.isRecentlyActive }
            let d0 = $0.lastActivityAt ?? .distantPast
            let d1 = $1.lastActivityAt ?? .distantPast
            return d0 > d1
        }
    }

    /// Phase 1 — fast: live PIDs + stat-only walk of recent JSONLs (last 24h).
    /// Reads no JSONL bodies; uses cached parses if available, otherwise leaves
    /// placeholder usage that Phase 2 will fill in. Sorted by recency.
    nonisolated static func scanLiveOnly(claudeDir: URL, customNames: [String: String]) -> [SessionInfo] {
        let sessionsDir = claudeDir.appendingPathComponent("sessions")
        let projectsDir = claudeDir.appendingPathComponent("projects")
        let recencyHorizon = Date().addingTimeInterval(-24 * 3600)

        var result: [SessionInfo] = []
        var seen: Set<String> = []

        // Live PIDs from sessions/
        if let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let pid = json["pid"] as? Int ?? Int(file.deletingPathExtension().lastPathComponent) ?? 0
                guard kill(Int32(pid), 0) == 0 else { continue }

                let sessionId = json["sessionId"] as? String ?? ""
                let cwd = json["cwd"] as? String ?? ""
                if isJunkCwd(cwd) { continue }

                let status = json["status"] as? String ?? "unknown"
                let version = json["version"] as? String ?? ""
                let startedAtMs = json["startedAt"] as? Double
                let startedAt = startedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }

                // Use cache if available, otherwise zero-valued placeholder until Phase 2.
                let (usage, model, aiTitle) = cachedParse(sessionId: sessionId)

                let cost = Pricing.cost(for: usage, model: model)
                let cacheHitRate: Double = {
                    let total = usage.cacheRead + usage.cacheCreation + usage.totalInput
                    guard total > 0 else { return 0 }
                    return Double(usage.cacheRead) / Double(total)
                }()
                let name = customNames[sessionId] ?? aiTitle ?? Self.shortPathStatic(cwd)
                result.append(SessionInfo(
                    id: sessionId, pid: pid, sessionId: sessionId, name: name,
                    cwd: cwd, status: status, startedAt: startedAt,
                    lastActivityAt: Date(),
                    version: version, model: model, usage: usage, cost: cost,
                    cacheHitRate: cacheHitRate, isAlive: true
                ))
                seen.insert(sessionId)
            }
        }

        // Recent JSONLs (last 24h, stat-only) so the sidebar isn't empty when no claude
        // process happens to be running. Phase 2 backfills full usage data.
        if let projects = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
            for project in projects {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let jsonls = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
                let cwdGuess = cwdFromProjectName(project.lastPathComponent)
                if isJunkCwd(cwdGuess) { continue }

                for url in jsonls where url.pathExtension == "jsonl" {
                    let sessionId = url.deletingPathExtension().lastPathComponent
                    if seen.contains(sessionId) { continue }
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let mtime = attrs[.modificationDate] as? Date,
                          mtime >= recencyHorizon else { continue }

                    let (usage, model, aiTitle) = cachedParse(sessionId: sessionId)
                    let cost = Pricing.cost(for: usage, model: model)
                    let cacheHitRate: Double = {
                        let total = usage.cacheRead + usage.cacheCreation + usage.totalInput
                        guard total > 0 else { return 0 }
                        return Double(usage.cacheRead) / Double(total)
                    }()
                    let name = customNames[sessionId] ?? aiTitle ?? Self.shortPathStatic(cwdGuess)
                    result.append(SessionInfo(
                        id: sessionId, pid: 0, sessionId: sessionId, name: name,
                        cwd: cwdGuess, status: "ended", startedAt: mtime,
                        lastActivityAt: mtime,
                        version: "", model: model, usage: usage, cost: cost,
                        cacheHitRate: cacheHitRate, isAlive: false
                    ))
                    seen.insert(sessionId)
                }
            }
        }

        return result
    }

    /// Excludes temp-folder sessions (sandboxed app working directories).
    nonisolated static func isJunkCwd(_ cwd: String) -> Bool {
        cwd.hasPrefix("/private/var/folders/") || cwd.hasPrefix("/var/folders/") || cwd.isEmpty
    }

    nonisolated static func cachedParse(sessionId: String) -> (TokenUsage, String?, String?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cache[sessionId] {
            return (c.usage, c.model, c.aiTitle)
        }
        return (TokenUsage(), nil, nil)
    }

    nonisolated static func projectNameFor(_ cwd: String) -> String {
        // ~/.claude/projects encodes paths as "-Users-mjm-projects-Foo"
        var s = cwd
        if s.hasPrefix("/") { s = String(s.dropFirst()) }
        return "-" + s.replacingOccurrences(of: "/", with: "-")
    }

    /// Phase 2 — full history scan within a horizon. Skips files older than horizon
    /// and files >100MB. Uses the size:mtime cache for instant re-runs.
    nonisolated static func scanHistory(claudeDir: URL, customNames: [String: String], days: Int) -> [SessionInfo] {
        let projectsDir = claudeDir.appendingPathComponent("projects")
        let horizon = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let maxFileBytes = 100 * 1024 * 1024

        guard let projects = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [SessionInfo] = []
        for project in projects {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let jsonls = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }

            for url in jsonls where url.pathExtension == "jsonl" {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int,
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if size > maxFileBytes { continue }
                if mtime < horizon { continue }

                let sessionId = url.deletingPathExtension().lastPathComponent
                let (usage, model, aiTitle, lastModified, cwdFromJsonl) = parseUsageStaticWithMeta(jsonlURL: url)
                let cwd = cwdFromJsonl ?? Self.cwdFromProjectName(project.lastPathComponent)
                if isJunkCwd(cwd) { continue }
                let cost = Pricing.cost(for: usage, model: model)
                let cacheHitRate: Double = {
                    let total = usage.cacheRead + usage.cacheCreation + usage.totalInput
                    guard total > 0 else { return 0 }
                    return Double(usage.cacheRead) / Double(total)
                }()
                let name = customNames[sessionId] ?? aiTitle ?? Self.shortPathStatic(cwd)
                result.append(SessionInfo(
                    id: sessionId, pid: 0, sessionId: sessionId, name: name,
                    cwd: cwd, status: "ended", startedAt: lastModified,
                    lastActivityAt: lastModified ?? mtime,
                    version: "", model: model, usage: usage, cost: cost,
                    cacheHitRate: cacheHitRate, isAlive: false
                ))
            }
        }
        return result
    }

    nonisolated static func cwdFromProjectName(_ name: String) -> String {
        // Project directory names are shell-encoded paths: "-Users-mjm-projects-MinionsCode" -> "/Users/mjm/projects/MinionsCode"
        // Best-effort decode — leading dash means root, dashes become slashes.
        var s = name
        if s.hasPrefix("-") { s = "/" + s.dropFirst() }
        return s.replacingOccurrences(of: "-", with: "/")
    }

    nonisolated private static func parseUsageStaticWithMeta(jsonlURL: URL) -> (TokenUsage, String?, String?, Date?, String?) {
        let sessionId = jsonlURL.deletingPathExtension().lastPathComponent
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlURL.path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date else {
            return (TokenUsage(), nil, nil, nil, nil)
        }
        let fingerprint = "\(size):\(mtime.timeIntervalSince1970)"

        cacheLock.lock()
        if let cached = cache[sessionId], cached.fingerprint == fingerprint {
            cacheLock.unlock()
            return (cached.usage, cached.model, cached.aiTitle, mtime, cached.cwd)
        }
        cacheLock.unlock()

        guard let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else {
            return (TokenUsage(), nil, nil, mtime, nil)
        }

        var usage = TokenUsage()
        var model: String?
        var aiTitle: String?
        var cwd: String?
        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if obj["type"] as? String == "ai-title" {
                aiTitle = obj["aiTitle"] as? String
            }
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let u = message["usage"] as? [String: Any] else { continue }
            usage.totalInput += u["input_tokens"] as? Int ?? 0
            usage.totalOutput += u["output_tokens"] as? Int ?? 0
            usage.cacheRead += u["cache_read_input_tokens"] as? Int ?? 0
            usage.cacheCreation += u["cache_creation_input_tokens"] as? Int ?? 0
            if obj["isSidechain"] as? Bool != true {
                usage.messageCount += 1
            }
            if let m = message["model"] as? String { model = m }
        }

        let snapshot = JsonlCache(fingerprint: fingerprint, usage: usage, model: model, aiTitle: aiTitle, cwd: cwd)
        cacheLock.lock()
        cache[sessionId] = snapshot
        cacheLock.unlock()
        return (usage, model, aiTitle, mtime, cwd)
    }

    func renameSession(_ id: String, to name: String) {
        customNames[id] = name.isEmpty ? nil : name
        saveNames()
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].name = name.isEmpty ? Self.shortPathStatic(sessions[idx].cwd) : name
        }
    }

    /// Auto-name unnamed sessions via Haiku one-shot. "Unnamed" = the displayed name
    /// equals the cwd shortPath (i.e., no AI title and no custom override).
    /// Limited to a max of 12 sessions per call to avoid runaway cost.
    func autoNameUnnamedSessions(filter: (SessionInfo) -> Bool = { _ in true }, maxCount: Int = 12) async {
        let candidates = sessions.filter { s in
            let isUnnamed = s.name == Self.shortPathStatic(s.cwd)
            return isUnnamed && s.usage.messageCount > 0 && filter(s)
        }.prefix(maxCount)

        for session in candidates {
            // Sample a snippet of the JSONL for context
            guard let snippet = await Self.sampleSession(sessionId: session.sessionId, projectsDir: claudeDir.appendingPathComponent("projects")) else { continue }
            let suggested = await AISearch.suggestName(forSnippet: snippet)
            if let name = suggested, !name.isEmpty {
                renameSession(session.id, to: name)
            }
        }
    }

    nonisolated static func sampleSession(sessionId: String, projectsDir: URL) async -> String? {
        guard let projects = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return nil }
        for project in projects {
            let url = project.appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Take first user message + first assistant text snippet — usually enough to name a session.
            var pieces: [String] = []
            for line in content.components(separatedBy: .newlines) where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] {
                    if let s = msg["content"] as? String { pieces.append("USER: " + String(s.prefix(400))) }
                    else if let arr = msg["content"] as? [[String: Any]],
                            let first = arr.first(where: { $0["type"] as? String == "text" }),
                            let s = first["text"] as? String { pieces.append("USER: " + String(s.prefix(400))) }
                }
                if obj["type"] as? String == "assistant", let msg = obj["message"] as? [String: Any],
                   let arr = msg["content"] as? [[String: Any]],
                   let first = arr.first(where: { $0["type"] as? String == "text" }),
                   let s = first["text"] as? String {
                    pieces.append("ASSISTANT: " + String(s.prefix(400)))
                }
                if pieces.count >= 4 { break }
            }
            return pieces.joined(separator: "\n\n").nilIfEmpty
        }
        return nil
    }
    @discardableResult
    func deleteJunkSessions() -> Int {
        let projectsDir = claudeDir.appendingPathComponent("projects")
        let sessionsToRemove = sessions.filter { s in
            !s.isAlive && (Self.isJunkCwd(s.cwd) || s.usage.messageCount == 0)
        }
        var removed = 0
        for s in sessionsToRemove {
            // Find the JSONL by walking projects/ for matching sessionId
            guard let projects = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { continue }
            for project in projects {
                let url = project.appendingPathComponent("\(s.sessionId).jsonl")
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        removed += 1
                    } catch {
                        // ignore — the user can retry
                    }
                    break
                }
            }
        }
        // Trim from in-memory list and from the cache.
        let removedIds = Set(sessionsToRemove.map(\.sessionId))
        sessions.removeAll { removedIds.contains($0.sessionId) }
        Self.cacheLock.lock()
        for id in removedIds { Self.cache.removeValue(forKey: id) }
        Self.cacheLock.unlock()
        return removed
    }

    private func loadNames() {
        guard let data = try? Data(contentsOf: namesFile),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        customNames = dict
    }

    private func saveNames() {
        let dir = namesFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: customNames, options: .prettyPrinted) {
            try? data.write(to: namesFile)
        }
    }

    private func shortPath(_ p: String) -> String {
        Self.shortPathStatic(p)
    }

    nonisolated private static func shortPathStatic(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }
}

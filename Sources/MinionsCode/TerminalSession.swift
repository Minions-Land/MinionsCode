import AppKit
import SwiftTerm

enum SessionMode {
    case shell
    case claude(resumeId: String?)
    /// Tail an existing session's JSONL — used when the session is alive
    /// elsewhere and we don't want to fork it via `claude --resume`.
    case watch(sessionId: String)

    var isWatch: Bool {
        if case .watch = self { return true }
        return false
    }

    /// The Claude session ID this terminal is bound to, if any.
    var sessionId: String? {
        switch self {
        case .shell: return nil
        case .claude(let rid): return rid
        case .watch(let sid): return sid
        }
    }

}

/// Singleton broker for the "you're read-only" toast.
/// One toast at a time across the whole app. Each new keystroke refreshes
/// the dismissal timer so it stays visible while the user keeps typing,
/// then fades out 2.5s after the last attempt.
@MainActor
@Observable
final class ReadOnlyToastCenter {
    static let shared = ReadOnlyToastCenter()
    var visibleSessionId: String?
    private var dismissTask: Task<Void, Never>?

    func signalAttempt(forSession id: String) {
        visibleSessionId = id
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            if !Task.isCancelled {
                self.visibleSessionId = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        visibleSessionId = nil
    }
}

/// Singleton that owns the *single* global NSEvent local monitor.
/// Per-tab monitors caused O(N) closures to run per keystroke; this fixes that.
@MainActor
final class TerminalKeyMonitor {
    static let shared = TerminalKeyMonitor()

    weak var activeSession: TerminalSession?
    nonisolated(unsafe) private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self,
                  let session = self.activeSession,
                  let window = session.terminalView.window,
                  window.firstResponder === session.terminalView else {
                return event
            }
            return self.handle(event, session: session)
        }
    }

    private func handle(_ event: NSEvent, session: TerminalSession) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let terminal = session.terminalView

        // Read-only: read state freshly from the session, not a cached flag.
        if session.isReadOnly {
            if mods.contains(.command) {
                let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if ["c", "a", "f"].contains(chars) { return event }
            }
            let sk = event.specialKey
            if sk == .pageUp || sk == .pageDown || sk == .home || sk == .end
                || sk == .upArrow || sk == .downArrow {
                return event
            }
            // User tried to type while read-only — surface the toast.
            ReadOnlyToastCenter.shared.signalAttempt(forSession: session.id)
            return nil
        }

        if mods.contains(.command) && (event.specialKey == .delete || event.keyCode == 51) {
            terminal.send(txt: "\u{15}"); return nil
        }
        if mods.contains(.command) && event.keyCode == 117 {
            terminal.send(txt: "\u{0B}"); return nil
        }
        if mods.contains(.command) && event.specialKey == .leftArrow {
            terminal.send(txt: "\u{01}"); return nil
        }
        if mods.contains(.command) && event.specialKey == .rightArrow {
            terminal.send(txt: "\u{05}"); return nil
        }
        if mods.contains(.option) && (event.specialKey == .delete || event.keyCode == 51) {
            terminal.send(txt: "\u{17}"); return nil
        }
        return event
    }
}

@MainActor
final class TerminalSession: @unchecked Sendable {
    let terminalView: LocalProcessTerminalView
    let mode: SessionMode
    let id: String
    /// Live CWD. Initialized to whatever was passed to init; updated by
    /// OSC 7 (hostCurrentDirectoryUpdate) when the shell emits it.
    /// The file explorer reads this via the .terminalCwdChanged notification.
    private(set) var cwd: String
    var isReadOnly: Bool = false
    private(set) var isRunning = false
    /// Set when the child process exits. nil = still running, 0 = clean exit, other = error.
    private(set) var exitCode: Int32? = nil
    /// Name of the deepest descendant process under the PTY's shell. Used by
    /// the tab to swap shell→claude icon when the user types `claude` inside
    /// a shell tab. Polled every 3s.
    private(set) var foregroundProcessName: String? = nil
    /// PID of the deepest descendant. Used to look up the live session ID
    /// from ~/.claude/sessions/<pid>.json — that way `/clear` (which keeps
    /// the same PID but issues a new session ID) is reflected in the tab.
    private(set) var foregroundProcessPID: pid_t? = nil
    /// Live Claude session ID for this terminal. For `.claude(resumeId:)`
    /// tabs this starts as the resume ID; for `.shell` tabs that have a
    /// claude child it's the live session ID. Updated by polling so /clear
    /// is reflected.
    private(set) var currentSessionId: String? = nil
    private var foregroundPollTask: Task<Void, Never>? = nil

    /// True when this is a shell tab whose user has launched a claude
    /// process inside it (covers the `claude`-typed-in-shell case).
    var hasClaudeChild: Bool {
        guard case .shell = mode else { return false }
        return foregroundProcessName == "claude"
    }

    init(mode: SessionMode = .shell, cwd: String? = nil) {
        self.mode = mode
        self.id = {
            switch mode {
            case .claude(let rid): return rid ?? UUID().uuidString
            case .watch(let sid): return sid
            case .shell: return UUID().uuidString
            }
        }()
        self.cwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path

        self.terminalView = MinionsTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        TerminalSession.applyDefaultTheme(to: terminalView)
        terminalView.optionAsMetaKey = true
        // Always render the caret as "focused" regardless of window focus state.
        // Without this, any brief focus loss (e.g. clicking the wrapper view,
        // switching to a menu) dims the caret — especially noticeable inside
        // Claude Code's readline prompt.
        terminalView.caretViewTracksFocus = false
        // I-beam (bar) cursor — much easier to read than the default block
        // which covers the character underneath it.
        terminalView.terminal.setCursorStyle(.blinkBar)
        // Bump scrollback from the default 500 lines — Claude Code sessions
        // easily produce thousands of lines of output, and the user wants
        // to scroll all the way back via the scroll bar. Configurable via
        // AppSettings.scrollbackLines.
        let scrollback = AppSettings.shared.scrollbackLines
        terminalView.terminal.options.scrollback = scrollback
        terminalView.terminal.buffer.changeHistorySize(scrollback)

        let env = buildEnv()
        switch mode {
        case .shell:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            terminalView.startProcess(executable: shell, args: ["-l"], environment: env, execName: "-\(URL(fileURLWithPath: shell).lastPathComponent)", currentDirectory: self.cwd)
        case .claude(let resumeId):
            self.isReadOnly = true
            let claudePath = findClaude()
            var args = [String]()
            if let rid = resumeId {
                args = ["--resume", rid]
            }
            // Defaults from AppSettings — user can override via the Run
            // Claude menu (one-off) or Settings → Claude defaults (persistent).
            let s = AppSettings.shared
            args += ["--model", s.defaultClaudeModel,
                     "--effort", s.defaultEffort,
                     "--permission-mode", s.defaultPermissionMode]
            if s.defaultLongContext { args += ["--betas", "context-1m-2025-08-07"] }
            if s.defaultDangerouslySkipPermissions { args += ["--dangerously-skip-permissions"] }
            terminalView.startProcess(executable: claudePath, args: args, environment: env, execName: "claude", currentDirectory: self.cwd)
        case .watch(let sessionId):
            self.isReadOnly = true
            let scriptPath = TerminalSession.ensureWatcherScript()
            terminalView.startProcess(
                executable: "/usr/bin/env",
                args: ["python3", "-u", scriptPath, sessionId],
                environment: env,
                execName: "watch-\(sessionId.prefix(8))",
                currentDirectory: self.cwd
            )
        }
        isRunning = true
        terminalView.processDelegate = self
        // Seed currentSessionId from the mode (if any) so the sidebar/tab
        // can display the right session right away.
        currentSessionId = mode.sessionId
        // Always poll: shell tabs may launch claude later, claude tabs
        // may /clear (same PID, new sessionId).
        startForegroundPolling()
    }

    /// Polls every 3s for the deepest descendant under the PTY's shell.
    /// Stops itself when the process exits. Cheap: ~1ms per tick.
    private func startForegroundPolling() {
        foregroundPollTask?.cancel()
        let rootPid = terminalView.process.shellPid
        let initialSessionId = mode.sessionId
        foregroundPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isRunning { return }
                let result = await Task.detached(priority: .background) {
                    TerminalSession.deepestDescendantInfo(of: rootPid)
                }.value
                let claudePid: pid_t? = result?.name == "claude" ? result?.pid : nil
                let liveSessionId = await Task.detached(priority: .background) {
                    TerminalSession.liveSessionId(forPID: claudePid)
                }.value ?? initialSessionId

                let nameChanged = self.foregroundProcessName != result?.name
                let pidChanged = self.foregroundProcessPID != claudePid
                let sessionChanged = self.currentSessionId != liveSessionId
                if nameChanged || pidChanged || sessionChanged {
                    self.foregroundProcessName = result?.name
                    self.foregroundProcessPID = claudePid
                    self.currentSessionId = liveSessionId
                    NotificationCenter.default.post(name: .terminalForegroundChanged, object: self)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Reads `~/.claude/sessions/<pid>.json` and returns the current
    /// sessionId for that PID, if the file exists and the PID is alive.
    /// Used so `/clear` (same PID, new sessionId) is reflected in the tab.
    nonisolated static func liveSessionId(forPID pid: pid_t?) -> String? {
        guard let pid = pid, pid > 0 else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = json["sessionId"] as? String, !sid.isEmpty else { return nil }
        return sid
    }

    /// Walks the process table once to find the deepest descendant of `root`.
    /// Walks the process table once to find the deepest descendant of `root`.
    /// Returns the executable name + pid (e.g. ("claude", 1234)), or nil if
    /// the only running descendant IS root (shell idle). Uses Darwin's
    /// proc_listpids.
    nonisolated static func deepestDescendantInfo(of root: pid_t) -> (name: String, pid: pid_t)? {
        if root == 0 { return nil }
        let bufSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufSize > 0 else { return nil }
        let count = Int(bufSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let written = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, bufSize)
        }
        guard written > 0 else { return nil }
        let actual = Int(written) / MemoryLayout<pid_t>.size
        var ppid = [pid_t: pid_t]()
        var name = [pid_t: String]()
        for p in pids.prefix(actual) where p > 0 {
            var info = proc_bsdinfo()
            let r = proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard r > 0 else { continue }
            ppid[p] = pid_t(info.pbi_ppid)
            let n = withUnsafePointer(to: info.pbi_comm) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.pbi_comm)) { String(cString: $0) }
            }
            name[p] = n
        }
        var descendants: [(pid: pid_t, depth: Int)] = []
        func walk(_ parent: pid_t, depth: Int) {
            for (child, par) in ppid where par == parent {
                descendants.append((child, depth))
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 1)
        guard let deepest = descendants.max(by: { $0.depth < $1.depth }),
              let n = name[deepest.pid] else { return nil }
        return (n, deepest.pid)
    }


    func sendCommand(_ command: String) {
        terminalView.send(txt: "\(command)\n")
    }

    func toggleReadOnly() {
        // Watch mode is permanently read-only — there's no live process to send to.
        if mode.isWatch { return }
        setReadOnly(!isReadOnly)
    }

    func setReadOnly(_ ro: Bool) {
        isReadOnly = ro
        // Physically remove keyboard focus when read-only — the terminal can still
        // be scrolled and selected, but cannot receive any keystrokes including
        // those that bypass our NSEvent monitor (IME, paste, etc.).
        guard let window = terminalView.window else { return }
        if ro && window.firstResponder === terminalView {
            window.makeFirstResponder(nil)
        } else if !ro && window.firstResponder !== terminalView {
            window.makeFirstResponder(terminalView)
        }
    }

    /// Activate keyboard handling for this terminal. Call when the user switches tabs.
    func activate() {
        TerminalKeyMonitor.shared.activeSession = self
        if !isReadOnly {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak terminalView] in
                terminalView?.window?.makeFirstResponder(terminalView)
            }
        }
    }

    func terminate() {
        terminalView.process.terminate()
        isRunning = false
    }

    static func applyDefaultTheme(to terminal: LocalProcessTerminalView) {
        let theme = AppSettings.shared.theme
        let translucent = AppSettings.shared.translucentBackground
        terminal.font = NSFont(name: "MesloLGS NF", size: AppSettings.shared.fontSize)
            ?? NSFont(name: "JetBrains Mono", size: AppSettings.shared.fontSize)
            ?? NSFont(name: "SF Mono", size: AppSettings.shared.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: AppSettings.shared.fontSize, weight: .regular)
        terminal.nativeForegroundColor = theme.foreground
        // Translucent: cells render fully transparent so the SwiftUI container
        // can paint a single uniform tint behind both the terminal AND its
        // padding margin — otherwise the cell area is darker than the margin.
        // Opaque: full theme background.
        terminal.nativeBackgroundColor = translucent ? .clear : theme.background
        terminal.caretColor = theme.primary
        terminal.selectedTextBackgroundColor = theme.primary.withAlphaComponent(0.3)

        // SwiftTerm initialises `layer.backgroundColor` from `nativeBackgroundColor`
        // ONCE in `setupOptions()`, then never reads it again — even if you change
        // `nativeBackgroundColor` later, the layer stays at the original opaque color.
        // For glass-effect translucency we must override the layer ourselves.
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = translucent
            ? NSColor.clear.cgColor
            : theme.background.cgColor
    }

    private func buildEnv() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "iTerm.app"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["MINIONSCODE"] = "1"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Drops a small Python tail-watcher into ~/.minionscode/ on first call and
    /// returns its path. Re-runs of the app overwrite if the embedded script
    /// changed (compared by content), so updates ship with the binary.
    static func ensureWatcherScript() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".minionscode")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("watch_session.py")
        let bytes = Data(watcherSource.utf8)
        let existing = try? Data(contentsOf: target)
        if existing != bytes {
            try? bytes.write(to: target)
            // chmod +x
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: target.path
            )
        }
        return target.path
    }

    private func findClaude() -> String {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/bin/claude").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return path }
        return "/opt/homebrew/bin/claude"
    }
}

@MainActor
extension TerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let dir = directory, !dir.isEmpty else { return }
        // The shell sends OSC 7 with file://hostname/abs/path or just abs/path.
        let path: String
        if dir.hasPrefix("file://") {
            if let url = URL(string: dir) { path = url.path } else { return }
        } else {
            path = dir
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.cwd != path {
                self.cwd = path
                NotificationCenter.default.post(
                    name: .terminalCwdChanged,
                    object: self,
                    userInfo: ["cwd": path]
                )
            }
        }
    }
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let code = exitCode
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
            self?.exitCode = code
        }
    }
}

/// Embedded Python source — written to ~/.minionscode/watch_session.py on first
/// watch tab open. Tails the JSONL for a session and pretty-prints turns.
private let watcherSource = #"""
#!/usr/bin/env python3
"""Tail a Claude Code session JSONL and pretty-print turns in real time.

Usage: watch_session.py <sessionId>

Locates ~/.claude/projects/*/<sessionId>.jsonl, follows it like `tail -f`,
and emits ANSI-colored output for user / assistant / tool / system events.
Read-only by design: this never writes to the JSONL or talks to the running
claude process, so it cannot disturb the live session.
"""
import os, sys, json, time, glob, signal

GOLD    = "\x1b[38;2;255;199;26m"
SKY     = "\x1b[38;2;102;204;255m"
LAVEND  = "\x1b[38;2;192;141;255m"
GREEN   = "\x1b[38;2;120;220;140m"
RED     = "\x1b[38;2;255;110;110m"
GREY    = "\x1b[38;2;130;130;140m"
DIM     = "\x1b[2m"
BOLD    = "\x1b[1m"
RESET   = "\x1b[0m"
CLEAR   = "\x1b[2J\x1b[H"

def find_jsonl(session_id):
    home = os.path.expanduser("~")
    pattern = os.path.join(home, ".claude", "projects", "*", f"{session_id}.jsonl")
    matches = glob.glob(pattern)
    if not matches:
        return None
    matches.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return matches[0]

def fmt_time(ts):
    if not ts: return ""
    try:
        from datetime import datetime
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime("%H:%M:%S")
    except Exception:
        return ""

def shorten(s, n=4000):
    s = (s or "").rstrip()
    return s if len(s) <= n else s[:n] + f"{DIM}…[+{len(s)-n} chars]{RESET}"

def render_user(msg, ts):
    content = msg.get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts = []
        for c in content:
            if c.get("type") == "text":
                parts.append(c.get("text", ""))
            elif c.get("type") == "tool_result":
                tid = c.get("tool_use_id", "")[:8]
                payload = c.get("content")
                if isinstance(payload, list):
                    payload = "\n".join(p.get("text", "") for p in payload if p.get("type") == "text")
                parts.append(f"{DIM}[tool_result {tid}]{RESET}\n{shorten(str(payload), 1200)}")
            else:
                parts.append(f"{DIM}[{c.get('type','?')}]{RESET}")
        text = "\n".join(parts)
    else:
        text = str(content or "")
    if text.strip():
        print(f"\n{SKY}{BOLD}USER{RESET} {DIM}{fmt_time(ts)}{RESET}")
        print(shorten(text))

def render_assistant(msg, ts):
    content = msg.get("content")
    model = msg.get("model", "")
    family = "OPUS" if "opus" in model.lower() else ("SONNET" if "sonnet" in model.lower() else ("HAIKU" if "haiku" in model.lower() else "?"))
    color = GOLD if family == "OPUS" else (SKY if family == "SONNET" else (LAVEND if family == "HAIKU" else GREY))
    if not isinstance(content, list):
        return
    head = False
    for c in content:
        if c.get("type") == "text":
            if not head:
                print(f"\n{color}{BOLD}{family}{RESET} {DIM}{fmt_time(ts)}{RESET}")
                head = True
            print(shorten(c.get("text", "")))
        elif c.get("type") == "tool_use":
            name = c.get("name", "?")
            tid = c.get("id", "")[:8]
            inp = c.get("input", {})
            try:
                preview = json.dumps(inp, ensure_ascii=False)[:200]
            except Exception:
                preview = str(inp)[:200]
            if not head:
                print(f"\n{color}{BOLD}{family}{RESET} {DIM}{fmt_time(ts)}{RESET}")
                head = True
            print(f"  {GREEN}↳ {name}{RESET} {DIM}{tid} {preview}{RESET}")
        elif c.get("type") == "thinking":
            if not head:
                print(f"\n{color}{BOLD}{family}{RESET} {DIM}{fmt_time(ts)}{RESET}")
                head = True
            print(f"  {DIM}[thinking…]{RESET}")

def render(line):
    try:
        obj = json.loads(line)
    except Exception:
        return
    t = obj.get("type")
    ts = obj.get("timestamp")
    if obj.get("isSidechain"):
        return  # skip sub-agent chatter
    if t == "user":
        render_user(obj.get("message", {}), ts)
    elif t == "assistant":
        render_assistant(obj.get("message", {}), ts)
    elif t == "summary":
        print(f"\n{GREY}{DIM}── summary: {shorten(str(obj.get('summary','')), 200)} ──{RESET}")

def header(session_id, path):
    print(f"{CLEAR}{GOLD}{BOLD}─── Watching session {session_id[:8]}… ───{RESET}")
    print(f"{DIM}File: {path}{RESET}")
    print(f"{DIM}Read-only — input is disabled. Updates appear live as the session writes.{RESET}\n")

def main():
    if len(sys.argv) < 2:
        print("Usage: watch_session.py <sessionId>")
        sys.exit(1)
    session_id = sys.argv[1]
    path = find_jsonl(session_id)
    if not path:
        print(f"{RED}No JSONL found for session {session_id}{RESET}")
        time.sleep(2)
        sys.exit(1)
    header(session_id, path)

    # Print backlog (last ~80 turns) so the user has context.
    backlog = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            backlog.append(line)
    for line in backlog[-160:]:
        render(line)
    print(f"\n{GREY}{DIM}── waiting for new events ──{RESET}", flush=True)

    # Tail loop
    inode = os.stat(path).st_ino
    pos = os.path.getsize(path)
    try:
        while True:
            try:
                st = os.stat(path)
                if st.st_ino != inode:
                    # File rotated — reopen from start.
                    inode = st.st_ino
                    pos = 0
                size = st.st_size
                if size < pos:
                    pos = 0
                if size > pos:
                    with open(path, "r", encoding="utf-8", errors="replace") as f:
                        f.seek(pos)
                        chunk = f.read(size - pos)
                        pos = size
                    for line in chunk.splitlines():
                        if line.strip():
                            render(line)
                    sys.stdout.flush()
            except FileNotFoundError:
                pass
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    main()
"""#

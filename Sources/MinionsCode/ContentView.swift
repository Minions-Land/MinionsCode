import SwiftUI
import AppKit

private let GOLD = Color(red: 1.0, green: 0.78, blue: 0.10)
private let GOLD_DIM = Color(red: 0.85, green: 0.66, blue: 0.08)
private let BG_DARKEST = Color(red: 0.04, green: 0.04, blue: 0.05)
private let BG_DARK = Color(red: 0.07, green: 0.07, blue: 0.08)
private let BG_MID = Color(red: 0.10, green: 0.10, blue: 0.11)
private let TEXT_PRIMARY = Color(red: 0.95, green: 0.93, blue: 0.86)
private let TEXT_DIM = Color.white.opacity(0.5)
private let TEXT_FAINT = Color.white.opacity(0.25)

/// Two unified opacity levels for chrome (everything that's not the terminal
/// itself). Top tier is the title-bar / sidebar-header row; mid tier is every
/// other strip. Same color base, just two alphas — keeps the glass look
/// consistent without losing visual hierarchy.
private let CHROME_TOP_ALPHA: Double = 0.55
private let CHROME_MID_ALPHA: Double = 0.32

/// Terminal cells render almost transparent so the surface is the lightest
/// of the three tiers — the visual hierarchy is title bar (deepest) →
/// chrome → terminal (lightest).
private let TERMINAL_ALPHA: Double = 0.18

struct ContentView: View {
    @State private var manager = SessionManager.shared
    @State private var settings = AppSettings.shared
    @State private var terminals: [String: TerminalSession] = [:]
    @State private var activeTerminalId: String?
    @State private var editingName: String?
    @State private var nameInput = ""
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var aiSearchHint: String?
    @State private var aiSearching = false
    @State private var sidebarCollapsed = true
    @State private var sidebarWidth: CGFloat = 320
    @State private var orderedTerminalIds: [String] = []
    @State private var showingCloseConfirm = false
    @State private var pendingCloseId: String?
    @State private var modelFilter: ModelFamilyFilter = .all

    private var sidebarTargetWidth: CGFloat {
        sidebarCollapsed ? 0 : sidebarWidth
    }

    var body: some View {
        rootContent
            .background(rootBackground)
            .preferredColorScheme(.dark)
            .environment(\.uiScale, settings.fontSize / 13.0)
            .onAppear(perform: handleOnAppear)
            .onChange(of: settings.theme) { _, _ in reapplyTheme() }
            .onChange(of: settings.fontSize) { _, _ in reapplyTheme() }
            .onChange(of: activeTerminalId) { _, _ in syncChromeBridge() }
            .onChange(of: sidebarCollapsed) { _, _ in syncChromeBridge() }
            .onChange(of: settings.translucentBackground) { _, _ in
                applyWindowTranslucency()
                reapplyTheme()
            }
            .modifier(GlobalNotifications(
                newShell: newShellSession,
                toggleSidebar: { withAnimation(.easeInOut(duration: 0.2)) { sidebarCollapsed.toggle() } },
                closeActive: { if let tid = activeTerminalId { closeTerminal(tid) } },
                showSettings: { showingSettings = true },
                zoomIn: { settings.fontSize = min(22, settings.fontSize + 1) },
                zoomOut: { settings.fontSize = max(9, settings.fontSize - 1) },
                zoomReset: { settings.fontSize = 13 },
                selectTab: { i in
                    if i >= 0 && i < orderedTerminalIds.count {
                        let tid = orderedTerminalIds[i]
                        activeTerminalId = tid
                        terminals[tid]?.activate()
                    }
                },
                nextTab: { switchTab(offset: 1) },
                prevTab: { switchTab(offset: -1) }
            ))
            .sheet(isPresented: $showingSettings) { SettingsSheet(isPresented: $showingSettings) }
            .alert("Close this tab?", isPresented: $showingCloseConfirm, presenting: pendingCloseId, actions: closeAlertActions, message: closeAlertMessage)
            .accentColor(GOLD)
            .tint(GOLD)
    }

    @ViewBuilder
    private func closeAlertActions(_ id: String) -> some View {
        Button("Cancel", role: .cancel) { pendingCloseId = nil }
        Button("Close", role: .destructive) {
            if let id = pendingCloseId { reallyCloseTerminal(id) }
            pendingCloseId = nil
        }
        .keyboardShortcut(.defaultAction)
    }

    private func closeAlertMessage(_ id: String) -> Text {
        Text("This terminal has a process running. Closing will terminate it.")
    }

    private var rootContent: some View {
        VStack(spacing: 0) {
            // titleRow lives in the NSWindow toolbar (see `.toolbar` modifier
            // on body) — that way it auto-hides with the traffic lights when
            // entering fullscreen, and reappears when the user mouses to the
            // top of the screen, exactly like Apple Terminal.
            tabsRow
            HStack(spacing: 0) {
                terminalPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !sidebarCollapsed {
                    SidebarResizer(width: $sidebarWidth)
                    sidebar
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .trailing))
                }
            }
        }
    }

    @ViewBuilder
    private var rootBackground: some View {
        if settings.translucentBackground {
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                // Match terminal alpha so the area behind sidebar resizer / margins
                // is the same lightness as the terminal — no bright seam.
                BG_DARKEST.opacity(TERMINAL_ALPHA)
            }
        } else {
            BG_DARKEST
        }
    }

    private func handleOnAppear() {
        manager.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        applyWindowTranslucency()
        if terminals.isEmpty { newShellSession() }
        DispatchQueue.main.async { installTitlebarChrome() }
        syncChromeBridge()
    }

    /// Push the latest activeTerminal + sidebar state into the AppKit-hosted
    /// chrome. Call after every state change that the chrome cares about.
    private func syncChromeBridge() {
        let bridge = ChromeBridge.shared
        bridge.activeTerminal = activeTerminal
        bridge.sidebarCollapsed = sidebarCollapsed
        bridge.onShowSettings = { NotificationCenter.default.post(name: .showSettings, object: nil) }
        bridge.onToggleSidebar = { NotificationCenter.default.post(name: .toggleSidebar, object: nil) }
        bridge.onDeleteJunk = {
            let n = SessionManager.shared.deleteJunkSessions()
            if n > 0 { SessionManager.shared.scan() }
        }
        bridge.onDeleteEmpty = { SessionManager.shared.scan() }
        bridge.onAutoNameOpus = {
            Task { await SessionManager.shared.autoNameUnnamedSessions { s in (s.model?.lowercased().contains("opus")) ?? false } }
        }
        bridge.onAutoNameAll = { Task { await SessionManager.shared.autoNameUnnamedSessions() } }
        bridge.onRefresh = { SessionManager.shared.scan() }
    }

    private func reapplyTheme() {
        for t in terminals.values {
            TerminalSession.applyDefaultTheme(to: t.terminalView)
        }
    }

    private func switchTab(offset: Int) {
        guard let tid = activeTerminalId,
              let idx = orderedTerminalIds.firstIndex(of: tid),
              !orderedTerminalIds.isEmpty else { return }
        let n = orderedTerminalIds.count
        let next = ((idx + offset) % n + n) % n
        let nextId = orderedTerminalIds[next]
        activeTerminalId = nextId
        terminals[nextId]?.activate()
    }

    private func applyWindowTranslucency() {
        guard let window = NSApp.windows.first else { return }
        // Always extend content under the title bar — the tabBar at the top of
        // our VStack is meant to occupy the SAME row as the traffic lights, with
        // the traffic lights floating on top. Without this, SwiftUI's safe area
        // pushes our content below the title bar and you get two rows.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        if settings.translucentBackground {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        }
    }

    /// Install the leading + trailing chrome as NSTitlebarAccessoryViewControllers
    /// directly into the title bar. This bypasses SwiftUI's `.toolbar` API
    /// (which forces a visual group around items) and lets each pill stand
    /// alone in the same row as the traffic lights — auto-hides in fullscreen.
    private func installTitlebarChrome() {
        guard let window = NSApp.windows.first else { return }
        // Already installed? (handleOnAppear can fire more than once across
        // theme changes etc.)
        let alreadyInstalled = window.titlebarAccessoryViewControllers.contains {
            ($0.view.identifier?.rawValue ?? "").hasPrefix("MinionsChrome.")
        }
        if alreadyInstalled { return }

        let bridge = ChromeBridge.shared
        let leading = NSTitlebarAccessoryViewController()
        let leadingHost = NSHostingView(rootView: TitlebarLeadingChrome(bridge: bridge))
        leadingHost.identifier = NSUserInterfaceItemIdentifier("MinionsChrome.leading")
        leadingHost.translatesAutoresizingMaskIntoConstraints = true
        leadingHost.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        leading.view = leadingHost
        leading.layoutAttribute = .leading

        let trailing = NSTitlebarAccessoryViewController()
        let trailingHost = NSHostingView(rootView: TitlebarTrailingChrome(bridge: bridge))
        trailingHost.identifier = NSUserInterfaceItemIdentifier("MinionsChrome.trailing")
        trailingHost.translatesAutoresizingMaskIntoConstraints = true
        trailingHost.frame = NSRect(x: 0, y: 0, width: 130, height: 28)
        trailing.view = trailingHost
        trailing.layoutAttribute = .trailing

        window.addTitlebarAccessoryViewController(leading)
        window.addTitlebarAccessoryViewController(trailing)
    }

    // MARK: - Helpers

    private var activeTerminal: TerminalSession? {
        activeTerminalId.flatMap { terminals[$0] }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().background(Color.white.opacity(0.05))
            filterBar
            Divider().background(Color.white.opacity(0.05))
            globalStats
            Divider().background(Color.white.opacity(0.05))
            sessionsList
            Divider().background(Color.white.opacity(0.05))
            sidebarFooter
        }
        .background(BG_DARKEST.opacity(settings.translucentBackground ? CHROME_MID_ALPHA : 1))
    }

    private var filterBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                FilterChip(label: "\(settings.historyHorizonDays)d", systemImage: "calendar", isOn: true) {
                    let next = (settings.historyHorizonDays == 7) ? 30 :
                               (settings.historyHorizonDays == 30) ? 1 :
                               (settings.historyHorizonDays == 1) ? 3 : 7
                    settings.historyHorizonDays = next
                    manager.scan()
                }
                FilterChip(label: "Empty", systemImage: "tray", isOn: !settings.hideEmptyFolders) {
                    settings.hideEmptyFolders.toggle()
                }
                FilterChip(label: "Inactive", systemImage: "moon.zzz", isOn: !settings.hideInactiveFolders) {
                    settings.hideInactiveFolders.toggle()
                }
                FilterChip(label: "Collapse", systemImage: "rectangle.compress.vertical", isOn: settings.collapseInactivesInFolder) {
                    settings.collapseInactivesInFolder.toggle()
                }
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(ModelFamilyFilter.allCases, id: \.self) { f in
                    ModelFilterChip(filter: f, isOn: modelFilter == f) {
                        modelFilter = (modelFilter == f) ? .all : f
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: aiSearching ? "sparkles" : "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(aiSearching ? GOLD : TEXT_DIM)
                TextField("Search sessions or ask AI…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(TEXT_PRIMARY)
                    .onSubmit { runAISearchIfNeeded() }
                if !searchText.isEmpty {
                    Button { searchText = ""; aiSearchHint = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundColor(TEXT_FAINT)
                }
                Button(action: runAISearchIfNeeded) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(searchText.isEmpty ? TEXT_FAINT : GOLD)
                }
                .buttonStyle(.plain)
                .help("AI search via Haiku — finds sessions by intent")
                .disabled(searchText.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BG_MID))

            if let hint = aiSearchHint {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9))
                    Text(hint).font(.system(size: 10)).lineLimit(2)
                }
                .foregroundColor(GOLD.opacity(0.85))
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var filteredSessions: [SessionInfo] {
        var result = manager.sessions
        if modelFilter != .all {
            result = result.filter { modelFilter.matches($0.model) }
        }
        guard !searchText.isEmpty else { return result }
        let q = searchText.lowercased()
        return result.filter { s in
            s.name.lowercased().contains(q)
                || s.cwd.lowercased().contains(q)
                || (s.model?.lowercased().contains(q) ?? false)
                || s.sessionId.lowercased().contains(q)
        }
    }

    private func runAISearchIfNeeded() {
        guard !searchText.isEmpty, !aiSearching else { return }
        // Only invoke AI if the literal filter returns nothing
        if !filteredSessions.isEmpty { return }
        aiSearching = true
        aiSearchHint = "Asking Haiku…"

        let query = searchText
        let snapshots: [[String: String]] = manager.sessions.prefix(40).map { s in
            [
                "id": s.sessionId,
                "name": s.name,
                "cwd": s.cwd,
                "messages": "\(s.usage.messageCount)",
                "cost": String(format: "%.2f", s.cost),
            ]
        }
        let sessionsForSearch = manager.sessions

        Task {
            let result = await AISearch.run(query: query, sessions: snapshots)
            aiSearching = false
            if let id = result.matchSessionId, let match = sessionsForSearch.first(where: { $0.sessionId == id }) {
                aiSearchHint = "→ \(match.name)"
                searchText = match.name
            } else {
                aiSearchHint = result.explanation ?? "No match found."
            }
        }
    }

    private var globalStats: some View {
        let totals = manager.sessions.reduce(into: TokenTotals()) { acc, s in
            acc.input += s.usage.totalInput
            acc.output += s.usage.totalOutput
            acc.cacheRead += s.usage.cacheRead
            acc.cacheCreation += s.usage.cacheCreation
        }
        let totalCost = manager.totalCost
        let hypotheticalCost = Double(totals.input + totals.cacheRead + totals.cacheCreation) / 1_000_000 * 15
                             + Double(totals.output) / 1_000_000 * 75
        let saved = max(0, hypotheticalCost - totalCost)

        return VStack(spacing: 12) {
            HStack(spacing: 0) {
                StatBlock(label: "ACTIVE", value: "\(manager.activeSessions)", color: GOLD)
                Spacer()
                StatBlock(label: "SPENT", value: fmtCost(totalCost), color: Color.orange)
                Spacer()
                StatBlock(label: "SAVED", value: fmtCost(saved), color: Color.green.opacity(0.85))
            }
            VStack(spacing: 4) {
                TokenRow(label: "Input", tokens: totals.input, price: 15, color: GOLD)
                TokenRow(label: "Cache R", tokens: totals.cacheRead, price: 1.5, color: Color.green.opacity(0.7))
                TokenRow(label: "Cache W", tokens: totals.cacheCreation, price: 18.75, color: Color.orange.opacity(0.8))
                TokenRow(label: "Output", tokens: totals.output, price: 75, color: Color.red.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(spacing: 4, pinnedViews: []) {
                if settings.groupByDirectory {
                    let groups = computeGroups()
                    ForEach(groups, id: \.title) { entry in
                        SessionGroup(
                            title: entry.title,
                            sessions: entry.sessions,
                            aliveCount: entry.aliveCount,
                            viewModel: viewModel
                        )
                    }
                } else {
                    ForEach(filteredSessions) { session in
                        SessionCard(session: session, viewModel: viewModel)
                    }
                }
                if manager.isLoadingHistory {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(.system(size: 11)).foregroundColor(TEXT_DIM)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    /// Folder grouping with filters and sort applied:
    /// - Hide empty folders / hide all-inactive folders (per AppSettings)
    /// - Sort by alive count desc, then by latest activity desc
    /// - Within a folder: alive first, then by last activity
    private func computeGroups() -> [(title: String, sessions: [SessionInfo], aliveCount: Int)] {
        let grouped = Dictionary(grouping: filteredSessions, by: { shortPath($0.cwd) })
        var entries: [(title: String, sessions: [SessionInfo], aliveCount: Int)] = []
        for (title, sessions) in grouped {
            let alive = sessions.filter(\.isAlive).count
            let recentlyActive = sessions.filter(\.isRecentlyActive).count
            if settings.hideEmptyFolders && sessions.isEmpty { continue }
            if settings.hideInactiveFolders && recentlyActive == 0 { continue }
            entries.append((title, sessions, alive))
        }
        entries.sort { a, b in
            if a.aliveCount != b.aliveCount { return a.aliveCount > b.aliveCount }
            let aLatest = a.sessions.compactMap(\.lastActivityAt).max() ?? .distantPast
            let bLatest = b.sessions.compactMap(\.lastActivityAt).max() ?? .distantPast
            return aLatest > bLatest
        }
        return entries
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Circle().fill(GOLD).frame(width: 5, height: 5)
            Text("\(manager.activeSessions) sessions")
                .font(.system(size: 10))
                .foregroundColor(TEXT_FAINT)
            Spacer()
            Text("v1.0")
                .font(.system(size: 10))
                .foregroundColor(TEXT_FAINT)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Terminal Panel

    private var terminalPanel: some View {
        ZStack {
            if let tid = activeTerminalId, let terminal = terminals[tid] {
                IsolatedTerminalView(terminal: terminal)
                    .id(tid)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .background(
                        // Lightest of the three tiers — chrome above, padding-margin
                        // here matches the cell area so the terminal is one surface.
                        BG_DARKEST.opacity(settings.translucentBackground ? TERMINAL_ALPHA : 1)
                    )
            } else {
                emptyState
            }
            ReadOnlyToastOverlay(
                activeTerminalId: activeTerminalId,
                isWatchMode: activeTerminalId.flatMap { terminals[$0]?.mode.isWatch } ?? false,
                onEnableEditing: {
                    if let tid = activeTerminalId, let t = terminals[tid] {
                        t.setReadOnly(false)
                    }
                }
            )
        }
        .background(BG_DARKEST.opacity(settings.translucentBackground ? TERMINAL_ALPHA : 1))
    }

    private func statusBadge(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundColor(.white.opacity(0.35))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
        }
    }

    /// Row 2 — tabs only, à la Terminal.app. Trailing `+` adds a new shell tab.
    private var tabsRow: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(orderedTerminalIds, id: \.self) { tid in
                        if let terminal = terminals[tid] {
                            TabChip(
                                terminal: terminal,
                                sessionName: nameForTerminal(terminal),
                                isActive: activeTerminalId == tid,
                                onSelect: {
                                    if activeTerminalId != tid {
                                        activeTerminalId = tid
                                        terminal.activate()
                                    }
                                },
                                onClose: { closeTerminal(tid) }
                            )
                        }
                    }
                    Button(action: newShellSession) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(TEXT_DIM)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("New shell tab (⌘T)")
                    .keyboardShortcut("t")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .frame(height: 32)
        .background(BG_DARKEST.opacity(settings.translucentBackground ? CHROME_MID_ALPHA : 1))
    }

    private func nameForTerminal(_ t: TerminalSession) -> String {
        if let sid = t.mode.sessionId,
           let session = manager.sessions.first(where: { $0.sessionId == sid }) {
            return session.name
        }
        switch t.mode {
        case .shell: return "shell"
        case .claude: return "claude"
        case .watch(let sid): return "watch \(sid.prefix(6))"
        }
    }

    private func closeTerminal(_ id: String) {
        // Always confirm — protects against ⌘W misfire and hides the
        // edge case where the user has work in progress.
        pendingCloseId = id
        showingCloseConfirm = true
    }

    private func reallyCloseTerminal(_ id: String) {
        terminals[id]?.terminate()
        terminals.removeValue(forKey: id)
        orderedTerminalIds.removeAll { $0 == id }
        if activeTerminalId == id {
            activeTerminalId = orderedTerminalIds.last
            if let next = activeTerminalId, let t = terminals[next] { t.activate() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            MinionDot(size: 56).opacity(0.6)
            VStack(spacing: 4) {
                Text("Welcome to MinionsCode")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(TEXT_PRIMARY)
                Text("A terminal with Claude Code superpowers")
                    .font(.system(size: 12))
                    .foregroundColor(TEXT_DIM)
            }
            HStack(spacing: 10) {
                Button(action: newShellSession) {
                    Label("New Shell", systemImage: "terminal")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(GOLD.opacity(0.12)))
                        .foregroundColor(GOLD)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n")
                Button(action: newClaudeSession) {
                    Label("New Claude", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                        .foregroundColor(TEXT_PRIMARY)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private var viewModel: SessionViewModel {
        SessionViewModel(
            activeId: activeTerminalId,
            editingId: editingName,
            nameInput: $nameInput,
            onSelect: selectSession,
            onResume: resumeSession,
            onRename: startRename,
            onCommitRename: commitRename
        )
    }

    private func newShellSession() {
        let cwd = manager.selectedSession?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let terminal = TerminalSession(mode: .shell, cwd: cwd)
        terminals[terminal.id] = terminal
        orderedTerminalIds.append(terminal.id)
        activeTerminalId = terminal.id
        terminal.activate()
    }

    private func newClaudeSession() {
        let terminal = TerminalSession(mode: .claude(resumeId: nil))
        terminals[terminal.id] = terminal
        orderedTerminalIds.append(terminal.id)
        activeTerminalId = terminal.id
        terminal.activate()
    }

    private func selectSession(_ session: SessionInfo) {
        if let existing = terminals[session.id] {
            activeTerminalId = session.id
            existing.activate()
        } else {
            resumeSession(session)
        }
    }

    private func resumeSession(_ session: SessionInfo) {
        if let existing = terminals[session.id] {
            activeTerminalId = session.id
            existing.activate()
            return
        }
        // Fresh liveness check at click time — `session.isAlive` is from polling
        // and might be a few seconds stale. Reading sessions/ directly here
        // ensures we never accidentally fork an active session.
        let liveNow = Self.isSessionAliveExternally(sessionId: session.sessionId)
        let mode: SessionMode = (session.isAlive || liveNow)
            ? .watch(sessionId: session.sessionId)
            : .claude(resumeId: session.sessionId)
        let terminal = TerminalSession(mode: mode, cwd: session.cwd)
        terminals[session.id] = terminal
        orderedTerminalIds.append(session.id)
        activeTerminalId = session.id
        terminal.activate()
    }

    /// Re-checks ~/.claude/sessions/ at click time so a stale poll snapshot
    /// can't trick us into resuming a session that's actually still running.
    private static func isSessionAliveExternally(sessionId: String) -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  sid == sessionId else { continue }
            let pid = obj["pid"] as? Int ?? Int(file.deletingPathExtension().lastPathComponent) ?? 0
            if kill(Int32(pid), 0) == 0 { return true }
        }
        return false
    }

    private func deleteEmptySessions() {
        // Close any tabs whose sessions had 0 user messages — heuristic for "never used".
        let toClose = terminals.values.compactMap { t -> String? in
            guard let sid = t.mode.sessionId,
                  let s = manager.sessions.first(where: { $0.sessionId == sid }),
                  s.usage.messageCount == 0 else { return nil }
            return t.id
        }
        for id in toClose { closeTerminal(id) }
    }

    private func startRename(_ session: SessionInfo) {
        nameInput = session.name
        editingName = session.id
    }

    private func commitRename(_ session: SessionInfo) {
        manager.renameSession(session.id, to: nameInput)
        editingName = nil
    }
}

/// Isolates the terminal NSView from parent SwiftUI re-renders.
/// Equatable on terminal id so updateNSView is a no-op when sessions update.
struct IsolatedTerminalView: View {
    let terminal: TerminalSession

    var body: some View {
        TerminalViewRepresentable(terminal: terminal)
    }
}

struct ReadOnlyToastOverlay: View {
    let activeTerminalId: String?
    let isWatchMode: Bool
    let onEnableEditing: () -> Void
    @State private var center = ReadOnlyToastCenter.shared

    var body: some View {
        VStack {
            if let tid = activeTerminalId, center.visibleSessionId == tid {
                HStack(spacing: 10) {
                    Image(systemName: isWatchMode ? "eye.fill" : "lock.fill")
                        .font(.system(size: 12))
                        .foregroundColor(isWatchMode ? Color.green : Color(red: 1.0, green: 0.78, blue: 0.10))
                    Text(isWatchMode ? "Watching live" : "Read-only mode")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("·")
                        .foregroundColor(.white.opacity(0.3))
                    Text(isWatchMode
                         ? "This session is running elsewhere — input is disabled to keep it intact"
                         : "Press ⌘E or click to enable editing")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                    if !isWatchMode {
                        Button("Enable") { onEnableEditing() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.2)))
                            .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.10))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.6))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .padding(.top, 12)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: center.visibleSessionId)
        .allowsHitTesting(center.visibleSessionId != nil)
    }
}

/// Singleton bridge between SwiftUI's ContentView state and the AppKit-hosted
/// title-bar chrome. The chrome lives in NSTitlebarAccessoryViewController
/// hosts that survive across SwiftUI re-renders, so they can't reach into
/// `ContentView`'s @State directly. ContentView pushes the latest values
/// here on every change; the chrome views observe via @Observable.
@MainActor
@Observable
final class ChromeBridge {
    static let shared = ChromeBridge()

    var activeTerminal: TerminalSession?
    var sidebarCollapsed: Bool = true
    var onShowSettings: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
    var onDeleteJunk: () -> Void = {}
    var onDeleteEmpty: () -> Void = {}
    var onAutoNameOpus: () -> Void = {}
    var onAutoNameAll: () -> Void = {}
    var onRefresh: () -> Void = {}
}

/// Leading title-bar accessory: Editing pill, cd pill, Run Claude pill.
/// Each pill is its own ChromePill — no shared wrapper around them.
struct TitlebarLeadingChrome: View {
    let bridge: ChromeBridge

    var body: some View {
        HStack(spacing: 6) {
            if let terminal = bridge.activeTerminal {
                if terminal.mode.isWatch {
                    ChromePill(accent: Color.green) {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.fill").font(.system(size: 11))
                            Text("read-only").font(.system(size: 11, weight: .medium))
                        }
                    }
                } else {
                    ReadOnlyToggle(terminal: terminal)
                    CdFolderButton(terminal: terminal)
                    if case .shell = terminal.mode {
                        ClaudeLaunchMenu(terminal: terminal)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Trailing title-bar accessory: segmented utility pill (⋯ / ⚙ / sidebar).
struct TitlebarTrailingChrome: View {
    let bridge: ChromeBridge

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ChromePillSegmentedActions(
                onShowSettings: bridge.onShowSettings,
                onToggleSidebar: bridge.onToggleSidebar,
                sidebarCollapsed: bridge.sidebarCollapsed,
                onDeleteJunk: bridge.onDeleteJunk,
                onDeleteEmpty: bridge.onDeleteEmpty,
                onAutoNameOpus: bridge.onAutoNameOpus,
                onAutoNameAll: bridge.onAutoNameAll,
                onRefresh: bridge.onRefresh
            )
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// Shared visual shell for every chrome control — `cd`, `Editing`,
/// `Run Claude`, etc. One source of truth for padding, corner radius,
/// border, hover/press state. Pass an optional `accent` to tint stateful
/// buttons (gold for `Editing`, etc.). The pill sizes itself to its
/// content vertically — never clips text — and is tall enough (~24pt)
/// to feel like a proper toolbar button.
struct ChromePill<Content: View>: View {
    var accent: Color? = nil
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content()
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        if let accent = accent { return accent.opacity(isEnabled ? 0.95 : 0.5) }
        return .white.opacity(isEnabled ? 0.78 : 0.4)
    }

    private var fill: Color {
        if let accent = accent {
            return accent.opacity(hovering ? 0.18 : 0.10)
        }
        return Color.white.opacity(hovering ? 0.10 : 0.05)
    }

    private var stroke: Color {
        if let accent = accent {
            return accent.opacity(hovering ? 0.45 : 0.25)
        }
        return Color.white.opacity(hovering ? 0.18 : 0.08)
    }
}

/// Segmented toolbar pill — bundles three icon buttons (⋯ menu, ⚙ settings,
/// sidebar toggle) into a single rounded shell with hairline dividers, like
/// AppKit's NSSegmentedControl. Lives at the right edge of the chrome row.
struct ChromePillSegmentedActions: View {
    let onShowSettings: () -> Void
    let onToggleSidebar: () -> Void
    let sidebarCollapsed: Bool
    let onDeleteJunk: () -> Void
    let onDeleteEmpty: () -> Void
    let onAutoNameOpus: () -> Void
    let onAutoNameAll: () -> Void
    let onRefresh: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button("Delete junk sessions (tmp / empty)") { onDeleteJunk() }
                Button("Delete empty tabs") { onDeleteEmpty() }
                Divider()
                Button("Auto-name unnamed Opus sessions") { onAutoNameOpus() }
                Button("Auto-name all unnamed sessions") { onAutoNameAll() }
                Divider()
                Button("Refresh now") { onRefresh() }
            } label: {
                segmentIcon(systemName: "ellipsis", weight: .bold, tint: nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            divider
            Button(action: onShowSettings) {
                segmentIcon(systemName: "gearshape", weight: .regular, tint: nil)
            }
            .buttonStyle(.plain)
            .help("Settings")

            divider
            Button(action: onToggleSidebar) {
                segmentIcon(
                    systemName: "sidebar.right",
                    weight: .regular,
                    tint: sidebarCollapsed ? nil : Color(red: 1.0, green: 0.78, blue: 0.10)
                )
            }
            .buttonStyle(.plain)
            .help(sidebarCollapsed ? "Show Claude sessions panel (⌘\\)" : "Hide panel (⌘\\)")
            .keyboardShortcut("\\")
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.16 : 0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private func segmentIcon(systemName: String, weight: Font.Weight, tint: Color?) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: weight))
            .foregroundColor(tint ?? Color.white.opacity(0.78))
            .frame(width: 28, height: 22)
            .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 0.5, height: 14)
    }
}


struct CdFolderButton: View {
    let terminal: TerminalSession

    var body: some View {
        Button(action: pickAndCd) {
            ChromePill {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text("cd").font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
        }
        .buttonStyle(.plain)
        .help("Pick a folder and cd into it")
    }

    private func pickAndCd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Choose a folder to cd into"
        panel.directoryURL = URL(fileURLWithPath: terminal.cwd)
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            // Quote to handle spaces
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            terminal.terminalView.send(txt: "cd \"\(escaped)\"\n")
        }
    }
}

struct ReadOnlyToggle: View {
    let terminal: TerminalSession
    @State private var readOnly = false

    var body: some View {
        Button {
            terminal.toggleReadOnly()
            readOnly = terminal.isReadOnly
        } label: {
            ChromePill(accent: readOnly ? nil : Color(red: 1.0, green: 0.78, blue: 0.10)) {
                HStack(spacing: 4) {
                    Image(systemName: readOnly ? "lock.fill" : "pencil.circle.fill")
                        .font(.system(size: 11))
                    Text(readOnly ? "Read-only" : "Editing")
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .buttonStyle(.plain)
        .help(readOnly ? "Read-only mode — click to enable editing (⌘E)" : "Editing mode — click to lock (⌘E)")
        .keyboardShortcut("e")
        .onAppear { readOnly = terminal.isReadOnly }
    }
}

struct ClaudeLaunchMenu: View {
    let terminal: TerminalSession
    @State private var showingPopover = false
    @State private var selectedModel: ClaudeModel = .auto
    @State private var effort: EffortLevel = .none
    @State private var permissionMode: PermissionMode = .none
    @State private var dangerouslySkipPermissions = false
    @State private var sandbox = false
    @State private var resumeMode: ResumeMode = .none
    @State private var forkSession = false
    @State private var verbose = false
    @State private var name: String = ""
    @State private var addDirs: String = ""
    @State private var worktreeEnabled = false
    @State private var worktreeName: String = ""
    @State private var print: String = ""

    enum ClaudeModel: String, CaseIterable, Identifiable {
        case auto, opus, opus47, sonnet, sonnet46, haiku, haiku45
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Default"
            case .opus: return "opus"
            case .opus47: return "opus-4-7"
            case .sonnet: return "sonnet"
            case .sonnet46: return "sonnet-4-6"
            case .haiku: return "haiku"
            case .haiku45: return "haiku-4-5"
            }
        }
        var flag: String? {
            switch self {
            case .auto: return nil
            case .opus: return "--model opus"
            case .opus47: return "--model claude-opus-4-7"
            case .sonnet: return "--model sonnet"
            case .sonnet46: return "--model claude-sonnet-4-6"
            case .haiku: return "--model haiku"
            case .haiku45: return "--model claude-haiku-4-5"
            }
        }
    }

    enum EffortLevel: String, CaseIterable, Identifiable {
        case none, low, medium, high, xhigh, max
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "Default"
            case .low: return "low"
            case .medium: return "medium"
            case .high: return "high"
            case .xhigh: return "xhigh"
            case .max: return "max"
            }
        }
        var flag: String? {
            self == .none ? nil : "--effort \(rawValue)"
        }
    }

    enum PermissionMode: String, CaseIterable, Identifiable {
        case none, defaultMode, acceptEdits, auto, bypassPermissions, dontAsk, plan
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "Default"
            case .defaultMode: return "default"
            case .acceptEdits: return "acceptEdits"
            case .auto: return "auto"
            case .bypassPermissions: return "bypassPermissions"
            case .dontAsk: return "dontAsk"
            case .plan: return "plan"
            }
        }
        var flag: String? {
            switch self {
            case .none: return nil
            case .defaultMode: return "--permission-mode default"
            case .acceptEdits: return "--permission-mode acceptEdits"
            case .auto: return "--permission-mode auto"
            case .bypassPermissions: return "--permission-mode bypassPermissions"
            case .dontAsk: return "--permission-mode dontAsk"
            case .plan: return "--permission-mode plan"
            }
        }
    }

    enum ResumeMode: String, CaseIterable, Identifiable {
        case none, resume, continueLast
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "None"
            case .resume: return "Resume"
            case .continueLast: return "Continue"
            }
        }
        var flag: String? {
            switch self {
            case .none: return nil
            case .resume: return "--resume"
            case .continueLast: return "--continue"
            }
        }
    }

    var composedCommand: String {
        var parts: [String] = []
        if sandbox { parts.append("IS_SANDBOX=1") }
        parts.append("claude")
        if let f = selectedModel.flag { parts.append(f) }
        if let f = effort.flag { parts.append(f) }
        if let f = permissionMode.flag { parts.append(f) }
        if dangerouslySkipPermissions { parts.append("--dangerously-skip-permissions") }
        if verbose { parts.append("--verbose") }
        if let f = resumeMode.flag { parts.append(f) }
        if forkSession && resumeMode != .none { parts.append("--fork-session") }
        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("--name \(name.shellQuoted())")
        }
        let dirs = addDirs.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if !dirs.isEmpty {
            parts.append("--add-dir " + dirs.map { $0.shellQuoted() }.joined(separator: " "))
        }
        if worktreeEnabled {
            let trimmed = worktreeName.trimmingCharacters(in: .whitespaces)
            parts.append(trimmed.isEmpty ? "--worktree" : "--worktree \(trimmed.shellQuoted())")
        }
        if !print.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("--print \(print.shellQuoted())")
        }
        return parts.joined(separator: " ")
    }

    var body: some View {
        Button { showingPopover = true } label: {
            ChromePill(accent: Color(red: 1.0, green: 0.78, blue: 0.10)) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text("Run Claude").font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            popoverContent
                .frame(width: 540)
                .frame(minHeight: 600, maxHeight: 720)
        }
    }

    private var popoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "sparkles").foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.10))
                    Text("Build a claude command").font(.system(size: 13, weight: .heavy))
                    Spacer()
                }

                Group {
                    section("MODEL") {
                        Picker("", selection: $selectedModel) {
                            ForEach(ClaudeModel.allCases) { m in Text(m.label).tag(m) }
                        }
                        .pickerStyle(.menu).labelsHidden()
                    }

                    section("EFFORT") {
                        Picker("", selection: $effort) {
                            ForEach(EffortLevel.allCases) { e in Text(e.label).tag(e) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }

                    section("PERMISSION MODE") {
                        Picker("", selection: $permissionMode) {
                            ForEach(PermissionMode.allCases) { m in Text(m.label).tag(m) }
                        }
                        .pickerStyle(.menu).labelsHidden()
                    }

                    section("FLAGS") {
                        Toggle(isOn: $sandbox) {
                            Text("IS_SANDBOX=1 (env prefix)")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        Toggle(isOn: $dangerouslySkipPermissions) {
                            Text("--dangerously-skip-permissions")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        Toggle(isOn: $verbose) {
                            Text("--verbose")
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }

                    section("RESUME") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $resumeMode) {
                                ForEach(ResumeMode.allCases) { r in Text(r.label).tag(r) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            Toggle(isOn: $forkSession) {
                                Text("--fork-session")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(resumeMode == .none ? .secondary : .primary)
                            }
                            .disabled(resumeMode == .none)
                        }
                    }

                    section("NAME") {
                        TextField("Display name (shown in /resume picker)", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }

                    section("WORKTREE") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $worktreeEnabled) {
                                Text("--worktree (new git worktree)")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            if worktreeEnabled {
                                TextField("Optional name", text: $worktreeName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                            }
                        }
                    }

                    section("ADDITIONAL DIRS (--add-dir)") {
                        TextField("space-separated paths", text: $addDirs)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    section("ONE-SHOT --print") {
                        TextField("Prompt for non-interactive run", text: $print)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }

                Divider()

                section("COMMAND PREVIEW") {
                    Text(composedCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.10))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.4)))
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Reset") { reset() }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(composedCommand, forType: .string)
                    }
                    Button("Run") {
                        terminal.sendCommand(composedCommand)
                        showingPopover = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 1.0, green: 0.78, blue: 0.10))
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).tracking(0.5)
            content()
        }
    }

    private func reset() {
        selectedModel = .auto
        effort = .none
        permissionMode = .none
        dangerouslySkipPermissions = false
        sandbox = false
        verbose = false
        resumeMode = .none
        forkSession = false
        name = ""
        addDirs = ""
        worktreeEnabled = false
        worktreeName = ""
        print = ""
    }
}

extension String {
    func shellQuoted() -> String {
        // Wrap in single quotes and escape any embedded single-quotes
        let escaped = self.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

struct TabChip: View {
    let terminal: TerminalSession
    let sessionName: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    private var statusIcon: (name: String, color: Color) {
        if terminal.isRunning {
            switch terminal.mode {
            case .shell:    return ("terminal", isActive ? GOLD : .white.opacity(0.5))
            case .claude:   return ("sparkles", isActive ? GOLD : .white.opacity(0.5))
            case .watch:    return ("eye", isActive ? GOLD : .white.opacity(0.5))
            }
        }
        // Process exited
        let code = terminal.exitCode ?? 0
        if code == 0 {
            return ("checkmark.circle.fill", Color.green.opacity(0.8))
        } else {
            return ("xmark.circle.fill", Color.red.opacity(0.8))
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon.name)
                .font(.system(size: 10))
                .foregroundColor(statusIcon.color)
            Text(sessionName)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .white : .white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(isHovering ? Color.white.opacity(0.1) : Color.clear))
                    .foregroundColor(.white.opacity(isHovering ? 0.8 : 0.4))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 100, maxWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.12) : Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isActive ? Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.4) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

struct SessionViewModel {
    let activeId: String?
    let editingId: String?
    let nameInput: Binding<String>
    let onSelect: (SessionInfo) -> Void
    let onResume: (SessionInfo) -> Void
    let onRename: (SessionInfo) -> Void
    let onCommitRename: (SessionInfo) -> Void
}

struct TokenTotals {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreation = 0
}

struct MinionDot: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(red: 1, green: 0.85, blue: 0.2), Color(red: 0.95, green: 0.65, blue: 0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .stroke(Color.black.opacity(0.6), lineWidth: max(1, size * 0.06))
            HStack(spacing: size * 0.08) {
                Circle().fill(Color.black).frame(width: size * 0.18, height: size * 0.18)
                Circle().fill(Color.black).frame(width: size * 0.18, height: size * 0.18)
            }
            .offset(y: -size * 0.05)
        }
        .frame(width: size, height: size)
    }
}

struct StatBlock: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.35))
                .tracking(0.5)
        }
    }
}

struct TokenRow: View {
    let label: String
    let tokens: Int
    let price: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 60, alignment: .leading)
            Text(fmtTokens(tokens))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Text(fmtCost(Double(tokens) / 1_000_000 * price))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color.opacity(0.95))
        }
    }
}

struct SessionGroup: View {
    let title: String
    let sessions: [SessionInfo]
    let aliveCount: Int
    let viewModel: SessionViewModel
    @State private var expanded = true
    @State private var hovering = false
    @State private var settings = AppSettings.shared
    @State private var showInactives = false

    private var sortedSessions: [SessionInfo] {
        sessions.sorted {
            if $0.isAlive != $1.isAlive { return $0.isAlive && !$1.isAlive }
            if $0.isRecentlyActive != $1.isRecentlyActive { return $0.isRecentlyActive && !$1.isRecentlyActive }
            let d0 = $0.lastActivityAt ?? .distantPast
            let d1 = $1.lastActivityAt ?? .distantPast
            return d0 > d1
        }
    }

    private var visibleSessions: [SessionInfo] {
        if settings.collapseInactivesInFolder && !showInactives {
            return sortedSessions.filter(\.isRecentlyActive)
        }
        return sortedSessions
    }

    private var hiddenInactiveCount: Int {
        guard settings.collapseInactivesInFolder, !showInactives else { return 0 }
        return sortedSessions.count - visibleSessions.count
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.5)
                    .lineLimit(1)
                Spacer()
                if aliveCount > 0 {
                    Text("\(aliveCount) live")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.10))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.15)))
                }
                Text("\(sessions.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.04) : Color.clear)
            )
            .foregroundColor(.white.opacity(0.55))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }

            if expanded {
                ForEach(visibleSessions) { session in
                    SessionCard(session: session, viewModel: viewModel)
                }
                if hiddenInactiveCount > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showInactives = true }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.down").font(.system(size: 9))
                            Text("Show \(hiddenInactiveCount) inactive")
                                .font(.system(size: 10, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct SessionCard: View {
    let session: SessionInfo
    let viewModel: SessionViewModel
    @Environment(\.uiScale) private var scale
    private var isActive: Bool { viewModel.activeId == session.id }
    private var isEditing: Bool { viewModel.editingId == session.id }
    private var dimmed: Bool { !session.isRecentlyActive }

    private var statusColor: Color {
        if session.isAlive {
            return session.status == "busy" ? Color(red: 1.0, green: 0.78, blue: 0.10) : Color.green
        }
        return session.isRecentlyActive ? Color.green.opacity(0.5) : Color.gray.opacity(0.35)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                if isEditing {
                    TextField("Name", text: viewModel.nameInput, onCommit: { viewModel.onCommitRename(session) })
                        .textFieldStyle(.plain)
                        .scaledFont(11, weight: .semibold)
                        .foregroundColor(.white)
                } else {
                    Text(session.name)
                        .scaledFont(11, weight: .semibold)
                        .foregroundColor(dimmed ? .white.opacity(0.45) : .white.opacity(0.92))
                        .lineLimit(1)
                }
                Spacer()
                ModelBadge(model: session.model, dimmed: dimmed)
                Text(fmtCost(session.cost))
                    .scaledFont(10, weight: .bold, design: .monospaced)
                    .foregroundColor(dimmed ? .orange.opacity(0.5) : .orange.opacity(0.85))
            }
            HStack(spacing: 8) {
                Text("\(session.usage.messageCount)msg")
                if let last = session.lastActivityAt {
                    Text(relativeTime(last))
                }
                Spacer()
                Text("⚡\(fmtPct(session.cacheHitRate))")
                    .foregroundColor(session.cacheHitRate > 0.7 ? .green.opacity(0.7) : .yellow.opacity(0.7))
            }
            .scaledFont(9, design: .monospaced)
            .foregroundColor(.white.opacity(0.32))

            // Per-session token breakdown — only show if session has data
            if session.usage.messageCount > 0 {
                HStack(spacing: 6) {
                    miniToken(label: "in", n: session.usage.totalInput, color: Color(red: 1.0, green: 0.78, blue: 0.10))
                    miniToken(label: "out", n: session.usage.totalOutput, color: Color.purple.opacity(0.85))
                    miniToken(label: "cR", n: session.usage.cacheRead, color: Color.green.opacity(0.7))
                    miniToken(label: "cW", n: session.usage.cacheCreation, color: Color.orange.opacity(0.7))
                }
                .opacity(dimmed ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.08) : Color.white.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isActive ? Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.4) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { viewModel.onSelect(session) }
        .contextMenu {
            Button("Resume in Terminal") { viewModel.onResume(session) }
            Button("Rename...") { viewModel.onRename(session) }
            Divider()
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionId, forType: .string)
            }
            Button("Open Folder in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
            }
        }
    }

    @ViewBuilder
    private func miniToken(label: String, n: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.system(size: 8)).foregroundColor(.white.opacity(0.3))
            Text(fmtTokens(n)).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(color)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.06)))
    }

    private func relativeTime(_ d: Date) -> String {
        let s = -d.timeIntervalSinceNow
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}

struct Pill: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(color)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.1)))
    }
}

struct SettingsSheet: View {
    @Binding var isPresented: Bool
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.system(size: 16, weight: .bold))
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                }
                .buttonStyle(.plain).foregroundColor(.white.opacity(0.5))
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Appearance").font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundColor(.white.opacity(0.5))
                HStack {
                    Text("Font Size")
                    Spacer()
                    Stepper("\(Int(settings.fontSize))pt", value: $settings.fontSize, in: 9...22, step: 1)
                        .labelsHidden()
                    Text("\(Int(settings.fontSize))pt").frame(width: 40)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Theme")
                    Spacer()
                    Picker("", selection: $settings.theme) {
                        ForEach(Theme.allCases, id: \.self) { t in Text(t.displayName).tag(t) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                Toggle("Translucent terminal background", isOn: $settings.translucentBackground)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Behavior").font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundColor(.white.opacity(0.5))
                Toggle("Group sessions by directory", isOn: $settings.groupByDirectory)
                Toggle("Notify when Claude finishes", isOn: $settings.notificationsEnabled)
                Toggle("Play sound on completion", isOn: $settings.soundEnabled).disabled(!settings.notificationsEnabled)
                HStack {
                    Text("Scrollback (lines)").font(.system(size: 12))
                    Spacer()
                    Stepper(
                        "\(settings.scrollbackLines.formatted())",
                        value: $settings.scrollbackLines,
                        in: 1_000...500_000,
                        step: 5_000
                    )
                    .help("Applies to new tabs. Larger values use more memory.")
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 460, height: 400)
        .background(BG_DARK)
        .preferredColorScheme(.dark)
    }
}

/// Bundles all the NotificationCenter subscriptions into one ViewModifier so the
/// ContentView body stays small enough for SwiftUI's type-checker to keep up.
struct GlobalNotifications: ViewModifier {
    let newShell: () -> Void
    let toggleSidebar: () -> Void
    let closeActive: () -> Void
    let showSettings: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomReset: () -> Void
    let selectTab: (Int) -> Void
    let nextTab: () -> Void
    let prevTab: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .newSession)) { _ in newShell() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in toggleSidebar() }
            .onReceive(NotificationCenter.default.publisher(for: .closeActiveTab)) { _ in closeActive() }
            .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in showSettings() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in zoomIn() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in zoomOut() }
            .onReceive(NotificationCenter.default.publisher(for: .zoomReset)) { _ in zoomReset() }
            .onReceive(NotificationCenter.default.publisher(for: .selectTab)) { note in
                if let i = note.object as? Int { selectTab(i) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .nextTab)) { _ in nextTab() }
            .onReceive(NotificationCenter.default.publisher(for: .prevTab)) { _ in prevTab() }
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

struct ScaledFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.uiScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

struct ModelBadge: View {
    let model: String?
    let dimmed: Bool

    private var family: (label: String, color: Color)? {
        guard let m = model?.lowercased() else { return nil }
        if m.contains("opus") { return ("OPUS", Color(red: 1.0, green: 0.78, blue: 0.10)) }
        if m.contains("sonnet") { return ("SONNET", Color(red: 0.40, green: 0.80, blue: 1.0)) }
        if m.contains("haiku") { return ("HAIKU", Color(red: 0.75, green: 0.55, blue: 1.0)) }
        return ("?", .gray)
    }

    var body: some View {
        if let f = family {
            Text(f.label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .tracking(0.5)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(f.color.opacity(dimmed ? 0.1 : 0.18)))
                .foregroundColor(f.color.opacity(dimmed ? 0.5 : 0.95))
        }
    }
}

enum ModelFamilyFilter: String, CaseIterable, Hashable {
    case all, opus, sonnet, haiku

    var label: String {
        switch self {
        case .all: return "All"
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        }
    }

    var color: Color {
        switch self {
        case .all: return Color(red: 1.0, green: 0.78, blue: 0.10)
        case .opus: return Color(red: 1.0, green: 0.78, blue: 0.10)
        case .sonnet: return Color(red: 0.40, green: 0.80, blue: 1.0)
        case .haiku: return Color(red: 0.75, green: 0.55, blue: 1.0)
        }
    }

    func matches(_ model: String?) -> Bool {
        guard self != .all else { return true }
        guard let m = model?.lowercased() else { return false }
        return m.contains(self.rawValue)
    }
}

struct ModelFilterChip: View {
    let filter: ModelFamilyFilter
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(filter.label)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .tracking(0.4)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    Capsule().fill(isOn ? filter.color.opacity(0.22) : Color.white.opacity(0.04))
                )
                .foregroundColor(isOn ? filter.color : .white.opacity(0.45))
        }
        .buttonStyle(.plain)
    }
}

struct FilterChip: View {
    let label: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(
                Capsule().fill(isOn ? Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.15) : Color.white.opacity(0.04))
            )
            .foregroundColor(isOn ? Color(red: 1.0, green: 0.78, blue: 0.10) : .white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }
}

struct SidebarResizer: View {
    @Binding var width: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.001))
            .frame(width: 4)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let newWidth = width - v.translation.width
                        width = max(220, min(500, newWidth))
                    }
            )
    }
}

/// NSVisualEffectView wrapper — gives the window the translucent vibrancy
/// effect like Terminal.app's "use background color with transparency" mode.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

func shortPath(_ p: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
    return p
}
func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
    return "\(n)"
}
func fmtCost(_ n: Double) -> String {
    if n >= 1000 { return String(format: "$%.0f", n) }
    if n >= 10 { return String(format: "$%.1f", n) }
    if n >= 1 { return String(format: "$%.2f", n) }
    return String(format: "$%.3f", n)
}
func fmtPct(_ n: Double) -> String { String(format: "%.0f%%", n * 100) }
func fmtDuration(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds / 60)
    if mins < 60 { return "\(mins)m" }
    let hrs = mins / 60
    if hrs < 24 { return "\(hrs)h\(mins % 60)m" }
    let days = hrs / 24
    return "\(days)d\(hrs % 24)h"
}

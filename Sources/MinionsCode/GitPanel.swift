import SwiftUI
import AppKit

// MARK: - Models

struct GitFileEntry: Identifiable, Hashable {
    enum Kind {
        case staged    // index ahead of HEAD
        case unstaged  // working tree ahead of index
        case untracked
    }
    let id: String       // "<kind>:<path>"
    let path: String     // relative to repo root
    let kind: Kind
    /// Two-char `git status --porcelain` code, e.g. " M", "M ", "??".
    let code: String
}

struct GitStatus {
    var repoRoot: URL?
    var branch: String = ""
    var ahead: Int = 0
    var behind: Int = 0
    var entries: [GitFileEntry] = []
    var error: String?

    var staged: [GitFileEntry] { entries.filter { $0.kind == .staged } }
    var unstaged: [GitFileEntry] { entries.filter { $0.kind == .unstaged } }
    var untracked: [GitFileEntry] { entries.filter { $0.kind == .untracked } }
}

@MainActor
@Observable
final class GitState {
    var status = GitStatus()
    var commitMessage: String = ""
    var diffText: String = ""
    var selectedEntry: GitFileEntry? = nil
    var pushing = false
    var lastError: String? = nil

    /// Bound to the active terminal's CWD. Setting this re-runs git status.
    var cwd: String = "" {
        didSet { if cwd != oldValue { Task { await refresh() } } }
    }

    func refresh() async {
        let cwd = self.cwd
        let result = await Task.detached(priority: .userInitiated) {
            GitState.queryStatus(at: cwd)
        }.value
        self.status = result
    }

    func reloadDiff() async {
        guard let entry = selectedEntry,
              let root = status.repoRoot else { diffText = ""; return }
        let staged = entry.kind == .staged
        let path = entry.path
        let rootPath = root.path
        let text = await Task.detached(priority: .userInitiated) {
            GitState.runGit([
                "diff",
                staged ? "--cached" : nil,
                "--",
                path
            ].compactMap { $0 }, at: rootPath) ?? ""
        }.value
        if entry.kind == .untracked && text.isEmpty {
            // For untracked files, show the whole file as diff.
            let url = root.appendingPathComponent(path)
            if let data = try? Data(contentsOf: url),
               let s = String(data: data.prefix(64_000), encoding: .utf8) {
                diffText = "// New file\n\n" + s
            } else {
                diffText = "// New file (binary or too large)"
            }
        } else {
            diffText = text
        }
    }

    func stage(_ entry: GitFileEntry) async {
        guard let root = status.repoRoot?.path else { return }
        _ = await Task.detached { GitState.runGit(["add", "--", entry.path], at: root) }.value
        await refresh()
    }
    func unstage(_ entry: GitFileEntry) async {
        guard let root = status.repoRoot?.path else { return }
        _ = await Task.detached { GitState.runGit(["restore", "--staged", "--", entry.path], at: root) }.value
        await refresh()
    }
    func discard(_ entry: GitFileEntry) async {
        guard let root = status.repoRoot?.path else { return }
        if entry.kind == .untracked {
            let url = URL(fileURLWithPath: root).appendingPathComponent(entry.path)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            _ = await Task.detached { GitState.runGit(["checkout", "--", entry.path], at: root) }.value
        }
        await refresh()
    }
    func stageAll() async {
        guard let root = status.repoRoot?.path else { return }
        _ = await Task.detached { GitState.runGit(["add", "-A"], at: root) }.value
        await refresh()
    }
    func commit() async {
        guard let root = status.repoRoot?.path,
              !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let msg = commitMessage
        let result = await Task.detached {
            GitState.runGit(["commit", "-m", msg], at: root)
        }.value
        if result == nil { lastError = "commit failed" }
        commitMessage = ""
        await refresh()
    }
    func push() async {
        guard let root = status.repoRoot?.path else { return }
        pushing = true
        let result = await Task.detached { GitState.runGit(["push"], at: root) }.value
        pushing = false
        if result == nil { lastError = "push failed (check terminal)" }
        await refresh()
    }

    // MARK: - Subprocess helpers

    nonisolated static func runGit(_ args: [String], at cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe() // discard
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated static func queryStatus(at cwd: String) -> GitStatus {
        var s = GitStatus()
        guard !cwd.isEmpty else { return s }
        // Resolve repo root
        guard let rootPath = runGit(["rev-parse", "--show-toplevel"], at: cwd)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !rootPath.isEmpty else {
            s.error = "Not a git repository"
            return s
        }
        s.repoRoot = URL(fileURLWithPath: rootPath)

        // Branch
        if let b = runGit(["branch", "--show-current"], at: rootPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
            s.branch = b
        } else {
            s.branch = runGit(["rev-parse", "--short", "HEAD"], at: rootPath)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "detached"
        }

        // Ahead/behind vs upstream
        if let counts = runGit(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], at: rootPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            let parts = counts.split(separator: "\t").compactMap { Int($0) }
            if parts.count == 2 { s.behind = parts[0]; s.ahead = parts[1] }
        }

        // Status (porcelain v1, NUL-separated for safety with renames/spaces)
        guard let raw = runGit(["status", "--porcelain=v1", "-z"], at: rootPath) else { return s }
        var entries: [GitFileEntry] = []
        // -z output: <XY> <space> <path> /dev/null  (for renames: <XY> <space> <new> /dev/null <old> /dev/null)
        let chunks = raw.split(separator: "\0", omittingEmptySubsequences: true)
        var i = 0
        while i < chunks.count {
            let chunk = String(chunks[i])
            guard chunk.count >= 3 else { i += 1; continue }
            let xy = String(chunk.prefix(2))
            let path = String(chunk.dropFirst(3))
            let x = xy.first!
            let y = xy.last!
            // Renames carry a follow-up old-path chunk; skip it.
            if x == "R" || x == "C" { i += 2 } else { i += 1 }
            if xy == "??" {
                entries.append(GitFileEntry(id: "untracked:\(path)", path: path, kind: .untracked, code: xy))
                continue
            }
            if x != " " && x != "?" {
                entries.append(GitFileEntry(id: "staged:\(path)", path: path, kind: .staged, code: xy))
            }
            if y != " " && y != "?" {
                entries.append(GitFileEntry(id: "unstaged:\(path)", path: path, kind: .unstaged, code: xy))
            }
        }
        s.entries = entries.sorted { $0.path < $1.path }
        return s
    }
}

// MARK: - Panel View

struct GitPanel: View {
    let activeTerminalCWD: String?

    @State private var state = GitState()
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.05))
            commitBox
            Divider().background(Color.white.opacity(0.05))
            content
        }
        .background(BG_DARKEST.opacity(settings.translucentBackground ? AppSettings.shared.chromeAlpha : 1))
        .onAppear {
            state.cwd = activeTerminalCWD ?? ""
        }
        .onChange(of: activeTerminalCWD) { _, new in
            state.cwd = new ?? ""
        }
        .onChange(of: state.selectedEntry) { _, _ in
            Task { await state.reloadDiff() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundColor(GOLD)
            Text(state.status.branch.isEmpty ? "no repo" : state.status.branch)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            if state.status.ahead > 0 {
                Text("↑\(state.status.ahead)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.green)
            }
            if state.status.behind > 0 {
                Text("↓\(state.status.behind)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.orange)
            }
            Spacer()
            iconButton(systemName: "arrow.clockwise", help: "Refresh") {
                Task { await state.refresh() }
            }
            iconButton(systemName: "arrow.up.circle", help: state.pushing ? "Pushing…" : "Push") {
                Task { await state.push() }
            }
            .disabled(state.pushing || state.status.repoRoot == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField("Commit message", text: $state.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1...4)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            HStack(spacing: 6) {
                Spacer()
                Button("Stage All") {
                    Task { await state.stageAll() }
                }
                .disabled(state.status.entries.isEmpty)
                Button("Commit") {
                    Task { await state.commit() }
                }
                .disabled(state.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty
                          || state.status.staged.isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let err = state.status.error {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(err).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        section("STAGED CHANGES", entries: state.status.staged)
                        section("CHANGES", entries: state.status.unstaged)
                        section("UNTRACKED", entries: state.status.untracked)
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 240)
                Divider().background(Color.white.opacity(0.05))
                diffPane
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, entries: [GitFileEntry]) -> some View {
        if !entries.isEmpty {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.6)
                    .foregroundColor(.white.opacity(0.4))
                Text("\(entries.count)")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
            ForEach(entries) { entry in
                GitFileRow(
                    entry: entry,
                    isSelected: state.selectedEntry == entry,
                    onSelect: { state.selectedEntry = entry },
                    onPrimaryAction: {
                        switch entry.kind {
                        case .staged: Task { await state.unstage(entry) }
                        case .unstaged, .untracked: Task { await state.stage(entry) }
                        }
                    },
                    onDiscard: { Task { await state.discard(entry) } }
                )
            }
        }
    }

    private var diffPane: some View {
        ScrollView {
            if state.diffText.isEmpty {
                Text("Select a file to view the diff")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
            } else {
                DiffText(text: state.diffText)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct GitFileRow: View {
    let entry: GitFileEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onPrimaryAction: () -> Void  // stage / unstage
    let onDiscard: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 6)
            Text(statusLetter)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 14)
            Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .white.opacity(0.78))
                .lineLimit(1)
            Text(directory)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if hovering {
                actionButton(systemName: "arrow.uturn.backward", help: "Discard") {
                    onDiscard()
                }
                actionButton(systemName: entry.kind == .staged ? "minus" : "plus",
                             help: entry.kind == .staged ? "Unstage" : "Stage") {
                    onPrimaryAction()
                }
            }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.10) :
                      (hovering ? Color.white.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
    }

    private var directory: String {
        let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
        return parent == "." ? "" : parent
    }

    private var statusLetter: String {
        switch entry.kind {
        case .staged:
            return String(entry.code.first ?? " ")
        case .unstaged:
            return String(entry.code.last ?? " ")
        case .untracked:
            return "U"
        }
    }
    private var statusColor: Color {
        switch entry.kind {
        case .untracked:               return .green
        case .staged:                  return Color(red: 0.55, green: 0.85, blue: 1.0)
        case .unstaged:
            let l = String(entry.code.last ?? " ")
            if l == "M" { return Color.orange }
            if l == "D" { return Color.red }
            return Color.white.opacity(0.7)
        }
    }

    private func actionButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Renders a unified diff with red/green tinting for +/- lines.
struct DiffText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(color(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }

    private func color<S: StringProtocol>(for line: S) -> Color {
        let s = String(line)
        if s.hasPrefix("+++") || s.hasPrefix("---") { return .white.opacity(0.5) }
        if s.hasPrefix("+") { return Color.green.opacity(0.85) }
        if s.hasPrefix("-") { return Color.red.opacity(0.85) }
        if s.hasPrefix("@@") { return Color(red: 0.6, green: 0.8, blue: 1.0).opacity(0.7) }
        return .white.opacity(0.78)
    }
}

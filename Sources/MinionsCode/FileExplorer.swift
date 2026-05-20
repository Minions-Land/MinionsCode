import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - Data Model

/// File-system node displayed in the explorer tree. Children are loaded
/// lazily — only on first expansion — so a folder with thousands of files
/// at depth doesn't lock up the UI on launch.
@MainActor
@Observable
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]? = nil
    var isExpanded: Bool = false
    var loadError: String? = nil

    nonisolated var id: String { url.path }
    nonisolated var name: String { url.lastPathComponent }

    /// Cached file kind so the icon/color path doesn't sniff bytes
    /// on every render. Folders skip the lookup entirely.
    let kind: FileKind

    nonisolated init(url: URL) {
        self.url = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
        // Skip kind detection for folders (we render a folder icon regardless)
        // and skip the byte-sniff fallback at construction time — only do
        // extension match. The sniff happens lazily inside FilePreview if
        // the user actually selects an unknown-extension file.
        self.kind = isDir.boolValue ? .binary : FileKind.detectByExtension(url)
    }

    /// Load immediate children synchronously on the main actor. Used for
    /// initial root setup (we want children available before render).
    /// For lazy expansion, prefer `loadChildrenAsync` which keeps the
    /// expand toggle from blocking the UI on large folders.
    func loadChildren() {
        guard isDirectory else { return }
        let kids = Self.readDirectory(at: url)
        self.children = kids.children
        self.loadError = kids.error
    }

    /// Off-main directory read so toggling a folder with thousands of
    /// entries doesn't freeze the click. Resolves on main with the
    /// loaded children. Use `await` from a Task triggered by user input.
    func loadChildrenAsync() async {
        guard isDirectory else { return }
        let target = url
        let result = await Task.detached(priority: .userInitiated) {
            FileNode.readDirectoryNonisolated(at: target)
        }.value
        // Re-check that we're still expecting these children (the user
        // may have collapsed and re-expanded; we're cheap to redo).
        self.children = result.children
        self.loadError = result.error
    }

    /// MainActor-friendly entry point for Self.readDirectoryNonisolated —
    /// safe to call from synchronous main-actor code.
    private static func readDirectory(at url: URL) -> (children: [FileNode], error: String?) {
        return readDirectoryNonisolated(at: url)
    }

    /// Pure file-system read. No actor isolation — the FileNode instances
    /// it constructs are also nonisolated (a fresh init), so handing them
    /// back to MainActor on the next line is fine.
    nonisolated static func readDirectoryNonisolated(at url: URL) -> (children: [FileNode], error: String?) {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                options: [.skipsPackageDescendants]
            )
            let kids = urls
                .filter { $0.lastPathComponent != ".DS_Store" }
                .map { FileNode(url: $0) }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            return (kids, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    /// Reload children, preserving expansion state of subfolders that still exist.
    func refresh() {
        guard isDirectory else { return }
        let oldExpanded = Set((children ?? []).filter(\.isExpanded).map(\.id))
        loadChildren()
        if let kids = children {
            for k in kids where oldExpanded.contains(k.id) {
                k.isExpanded = true
                k.loadChildren()
            }
        }
    }
}

// MARK: - File Type Detection

enum FileKind {
    case text         // .txt .log .conf etc.
    case sourceCode   // .swift .py .js .ts .go .rb etc.
    case markup       // .md .markdown
    case json
    case yaml
    case toml
    case html
    case css
    case shellScript
    case image        // .png .jpg .gif .heic .webp .svg
    case pdf
    case binary       // unknown / not previewable

    /// Extension-only detection — fast, used for the tree row icon/color
    /// path. Falls back to .binary for unknown extensions; the preview
    /// pane upgrades to .text via byte-sniff if the user opens it.
    static func detectByExtension(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdx":            return .markup
        case "json", "jsonl", "ndjson":          return .json
        case "yaml", "yml":                       return .yaml
        case "toml":                              return .toml
        case "html", "htm", "xhtml":              return .html
        case "css", "scss", "sass", "less":       return .css
        case "sh", "bash", "zsh", "fish":         return .shellScript
        case "py", "swift", "js", "ts", "tsx",
             "jsx", "go", "rs", "rb", "java",
             "kt", "c", "cc", "cpp", "h", "hpp",
             "m", "mm", "lua", "php", "pl",
             "sql", "swiftinterface":              return .sourceCode
        case "png", "jpg", "jpeg", "gif", "heic",
             "heif", "webp", "tiff", "bmp", "svg": return .image
        case "pdf":                                return .pdf
        case "txt", "log", "conf", "cfg", "ini",
             "env", "gitignore", "gitattributes",
             "rtf":                                return .text
        default:                                   return .binary
        }
    }

    /// Heuristic: extension first, then content sniff for unknown types.
    /// Used by FilePreview which can afford the I/O.
    static func detect(_ url: URL) -> FileKind {
        let byExt = detectByExtension(url)
        if byExt != .binary { return byExt }
        // No extension or unknown: sniff first 4KB.
        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]).prefix(4096),
           data.allSatisfy({ $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || ($0 >= 0x20 && $0 < 0x7F) || $0 >= 0x80 }) {
            return .text
        }
        return .binary
    }

    var iconName: String {
        switch self {
        case .text:        return "doc.text"
        case .sourceCode:  return "chevron.left.forwardslash.chevron.right"
        case .markup:      return "doc.richtext"
        case .json:        return "curlybraces"
        case .yaml, .toml: return "list.bullet.indent"
        case .html:        return "globe"
        case .css:         return "paintbrush"
        case .shellScript: return "terminal"
        case .image:       return "photo"
        case .pdf:         return "doc.fill"
        case .binary:      return "doc"
        }
    }
}

// MARK: - Explorer Panel

/// Top-level VS Code-style explorer. Two sections (CWD-tracking root and
/// pinned roots) plus a preview area at the bottom showing the selected file.
/// Visible state is local; persistent state (auto-follow, pinned, width)
/// lives on AppSettings.
struct FileExplorerPanel: View {
    /// Initial CWD when the active terminal switches; subsequent OSC 7
    /// updates from the live terminal arrive via .terminalCwdChanged.
    let activeTerminalId: String?
    let activeTerminalCWD: String?

    @State private var settings = AppSettings.shared
    @State private var cwdRoot: FileNode?
    @State private var manualRoot: FileNode?
    @State private var pinnedRoots: [FileNode] = []
    @State private var selectedURL: URL?
    @State private var renaming: URL?
    @State private var renameText: String = ""
    @State private var pendingDelete: URL?
    @State private var showingNewFile = false
    @State private var newFileParent: URL?
    @State private var newFileText: String = ""
    @State private var newFileIsFolder = false

    private var topRoot: FileNode? {
        settings.explorerAutoFollow ? cwdRoot : manualRoot
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.05))
            scrollContents
            if let url = selectedURL {
                Divider().background(Color.white.opacity(0.05))
                FilePreview(url: url)
                    .frame(minHeight: 200, idealHeight: 280, maxHeight: 380)
            }
        }
        .background(BG_DARKEST.opacity(settings.translucentBackground ? AppSettings.shared.chromeAlpha : 1))
        .onAppear { rebuildCwdRoot(from: activeTerminalCWD); rebuildPinned() }
        .onChange(of: activeTerminalCWD) { _, new in rebuildCwdRoot(from: new) }
        .onChange(of: settings.explorerAutoFollow) { _, _ in rebuildCwdRoot(from: activeTerminalCWD) }
        .onChange(of: settings.pinnedFolders) { _, _ in rebuildPinned() }
        .onReceive(NotificationCenter.default.publisher(for: .terminalCwdChanged)) { note in
            guard let session = note.object as? TerminalSession,
                  session.id == activeTerminalId,
                  settings.explorerAutoFollow,
                  let cwd = note.userInfo?["cwd"] as? String else { return }
            rebuildCwdRoot(from: cwd)
        }
        .alert("Delete \(pendingDelete?.lastPathComponent ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), actions: {
            Button("Move to Trash", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }, message: { Text("This action moves the file to Trash. You can restore it from Finder if needed.") })
        .sheet(isPresented: $showingNewFile) { newFileSheet }
    }

    // MARK: Header (toolbar)

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("EXPLORER")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.6)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                iconButton(systemName: "doc.badge.plus", help: "New File") {
                    newFileParent = topRoot?.url
                    newFileIsFolder = false
                    newFileText = ""
                    showingNewFile = true
                }
                iconButton(systemName: "folder.badge.plus", help: "New Folder") {
                    newFileParent = topRoot?.url
                    newFileIsFolder = true
                    newFileText = ""
                    showingNewFile = true
                }
                iconButton(systemName: "arrow.clockwise", help: "Refresh") {
                    cwdRoot?.refresh()
                    manualRoot?.refresh()
                    pinnedRoots.forEach { $0.refresh() }
                }
                iconButton(
                    systemName: settings.explorerAutoFollow ? "link" : "link.circle",
                    help: settings.explorerAutoFollow ? "Auto-follow CWD (on) — click to switch to manual" : "Manual folder — click to follow CWD",
                    tint: settings.explorerAutoFollow ? GOLD : nil
                ) {
                    settings.explorerAutoFollow.toggle()
                    if settings.explorerAutoFollow { manualRoot = nil }
                }
                iconButton(systemName: "folder", help: "Open Folder…") {
                    pickFolder()
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private func iconButton(systemName: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint ?? .white.opacity(0.6))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Body sections

    private var scrollContents: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                sectionHeader(
                    title: settings.explorerAutoFollow ? "CWD" : "FOLDER",
                    subtitle: topRoot?.url.lastPathComponent ?? "no terminal"
                )
                if let root = topRoot {
                    FileTreeRow(
                        node: root,
                        depth: 0,
                        selectedURL: $selectedURL,
                        renaming: $renaming,
                        renameText: $renameText,
                        pendingDelete: $pendingDelete,
                        onCommitRename: commitRename,
                        showRoot: true
                    )
                } else {
                    Text("No active terminal")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 12)
                }

                HStack(spacing: 6) {
                    Text("PINNED")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.6)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Button {
                        if let p = topRoot?.url.path,
                           !settings.pinnedFolders.contains(p) {
                            settings.pinnedFolders.append(p)
                        }
                    } label: {
                        Image(systemName: "pin")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Pin current folder")
                    .disabled(topRoot == nil)
                    Button {
                        pickAndPinFolder()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Pin a different folder")
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
                if pinnedRoots.isEmpty {
                    Text("No pinned folders. Use the pin icon to keep folders here.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                ForEach(pinnedRoots) { root in
                    FileTreeRow(
                        node: root,
                        depth: 0,
                        selectedURL: $selectedURL,
                        renaming: $renaming,
                        renameText: $renameText,
                        pendingDelete: $pendingDelete,
                        onCommitRename: commitRename,
                        showRoot: true,
                        onUnpin: { unpin(root.url) }
                    )
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(title: String, subtitle: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(.white.opacity(0.4))
            if let s = subtitle {
                Text(s)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: Helpers

    private func rebuildCwdRoot(from path: String?) {
        guard let path = path else { cwdRoot = nil; return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let node = FileNode(url: url)
        node.isExpanded = true
        node.loadChildren()
        cwdRoot = node
    }

    private func rebuildPinned() {
        pinnedRoots = settings.pinnedFolders.compactMap { p in
            let u = URL(fileURLWithPath: p, isDirectory: true)
            guard FileManager.default.fileExists(atPath: u.path) else { return nil }
            let n = FileNode(url: u)
            n.isExpanded = true
            n.loadChildren()
            return n
        }
    }

    private func unpin(_ url: URL) {
        settings.pinnedFolders.removeAll { $0 == url.path }
    }

    private func pickAndPinFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Pin folder to Explorer"
        if panel.runModal() == .OK, let url = panel.url,
           !settings.pinnedFolders.contains(url.path) {
            settings.pinnedFolders.append(url.path)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Open folder in Explorer"
        if panel.runModal() == .OK, let url = panel.url {
            settings.explorerAutoFollow = false
            let node = FileNode(url: url)
            node.isExpanded = true
            node.loadChildren()
            manualRoot = node
        }
    }

    private func commitRename(_ url: URL, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else {
            renaming = nil; return
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            renaming = nil
            // Refresh trees so the new name shows up
            cwdRoot?.refresh()
            manualRoot?.refresh()
            pinnedRoots.forEach { $0.refresh() }
            if selectedURL == url { selectedURL = dest }
        } catch {
            NSSound.beep()
            renaming = nil
        }
    }

    private func performDelete() {
        guard let url = pendingDelete else { return }
        defer { pendingDelete = nil }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            cwdRoot?.refresh()
            manualRoot?.refresh()
            pinnedRoots.forEach { $0.refresh() }
            if selectedURL == url { selectedURL = nil }
        } catch {
            NSSound.beep()
        }
    }

    private var newFileSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(newFileIsFolder ? "New Folder" : "New File")
                .font(.system(size: 14, weight: .semibold))
            if let parent = newFileParent {
                Text("In: \(parent.path)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            TextField(newFileIsFolder ? "folder-name" : "file.ext", text: $newFileText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { performNewFile() }
            HStack {
                Spacer()
                Button("Cancel") { showingNewFile = false }
                    .keyboardShortcut(.cancelAction)
                Button(newFileIsFolder ? "Create Folder" : "Create File") { performNewFile() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFileText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func performNewFile() {
        let trimmed = newFileText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parent = newFileParent else { return }
        let dest = parent.appendingPathComponent(trimmed)
        do {
            if newFileIsFolder {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            } else {
                try Data().write(to: dest)
            }
            cwdRoot?.refresh()
            manualRoot?.refresh()
            pinnedRoots.forEach { $0.refresh() }
            selectedURL = newFileIsFolder ? nil : dest
            showingNewFile = false
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Tree Row (recursive)

struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    @Binding var selectedURL: URL?
    @Binding var renaming: URL?
    @Binding var renameText: String
    @Binding var pendingDelete: URL?
    let onCommitRename: (URL, String) -> Void
    var showRoot: Bool = false
    var onUnpin: (() -> Void)? = nil

    @State private var isHovering = false
    @AppStorage("minionscode.explorerHideHidden") private var hideHidden = false

    private var isSelected: Bool { selectedURL == node.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if node.isExpanded, let kids = node.children {
                ForEach(kids) { child in
                    FileTreeRow(
                        node: child,
                        depth: depth + 1,
                        selectedURL: $selectedURL,
                        renaming: $renaming,
                        renameText: $renameText,
                        pendingDelete: $pendingDelete,
                        onCommitRename: onCommitRename
                    )
                }
                .transition(.opacity)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            // Indent
            Spacer().frame(width: CGFloat(depth) * 12 + 6)
            // Disclosure chevron (folder only)
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            // Icon
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundColor(iconColor)
                .frame(width: 14)
            // Label or rename field
            if renaming == node.url {
                TextField(node.name, text: $renameText, onCommit: {
                    onCommitRename(node.url, renameText)
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onExitCommand { renaming = nil }
            } else {
                Text(node.name)
                    .font(.system(size: 11, weight: showRoot && depth == 0 ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            // Hover-revealed action buttons
            if isHovering && renaming != node.url {
                hoverActions
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.10) :
                      (isHovering ? Color.white.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Single click reacts immediately — toggling folders or selecting
        // files. A separate count:2 gesture in .simultaneousGesture handles
        // double click on FILES only (open in default app). Folders never
        // need a double-click handler, so they don't pay for one.
        .onTapGesture {
            if node.isDirectory {
                expandFolder()
            } else {
                selectedURL = node.url
            }
        }
        .simultaneousGesture(
            node.isDirectory ? nil :
            TapGesture(count: 2).onEnded { NSWorkspace.shared.open(node.url) }
        )
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
            Button("Copy Relative Path") {
                let cwd = FileManager.default.currentDirectoryPath
                let rel = node.url.path.replacingOccurrences(
                    of: cwd + "/", with: "", options: .anchored
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rel, forType: .string)
            }
            Button("Copy File Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.name, forType: .string)
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Button("Open in Default App") {
                NSWorkspace.shared.open(node.url)
            }
            if node.isDirectory {
                Button("Open in Terminal (cd here)") {
                    let escaped = node.url.path.replacingOccurrences(of: "\"", with: "\\\"")
                    NotificationCenter.default.post(
                        name: .explorerCdRequest,
                        object: nil,
                        userInfo: ["path": escaped]
                    )
                }
                Button("Pin to Explorer") {
                    NotificationCenter.default.post(
                        name: .explorerPinRequest,
                        object: nil,
                        userInfo: ["path": node.url.path]
                    )
                }
            }
            Divider()
            Button("Rename") {
                renameText = node.name
                renaming = node.url
            }
            Button("Move to Trash", role: .destructive) {
                pendingDelete = node.url
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if node.isDirectory {
                actionButton(systemName: "doc.badge.plus", help: "New file in this folder") {
                    NotificationCenter.default.post(
                        name: .explorerNewFileInFolder,
                        object: nil,
                        userInfo: ["parent": node.url, "isFolder": false]
                    )
                }
            }
            actionButton(systemName: "pencil", help: "Rename") {
                renameText = node.name
                renaming = node.url
            }
            actionButton(systemName: "trash", help: "Move to Trash") {
                pendingDelete = node.url
            }
            if let onUnpin = onUnpin, depth == 0 {
                actionButton(systemName: "pin.slash", help: "Unpin") { onUnpin() }
            }
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

    private var iconName: String {
        if node.isDirectory {
            return node.isExpanded ? "folder.fill" : "folder"
        }
        return node.kind.iconName
    }

    private var iconColor: Color {
        if node.isDirectory { return Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.85) }
        switch node.kind {
        case .image:       return Color(red: 0.55, green: 0.85, blue: 0.55)
        case .pdf:         return Color(red: 1.00, green: 0.45, blue: 0.40)
        case .markup:      return Color(red: 0.65, green: 0.85, blue: 1.00)
        case .json, .yaml, .toml: return Color(red: 1.00, green: 0.80, blue: 0.55)
        case .sourceCode:  return Color(red: 0.85, green: 0.80, blue: 1.00)
        case .shellScript: return Color(red: 0.75, green: 0.95, blue: 0.85)
        default:           return .white.opacity(0.55)
        }
    }

    private func expandFolder() {
        if !node.isExpanded {
            // Load children if not yet loaded
            if node.children == nil || node.children?.isEmpty == true {
                node.children = []
                withAnimation(.easeOut(duration: 0.15)) {
                    node.isExpanded = true
                }
                Task { await node.loadChildrenAsync() }
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    node.isExpanded = true
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                node.isExpanded = false
            }
        }
    }
}

extension Notification.Name {
    static let explorerNewFileInFolder = Notification.Name("explorerNewFileInFolder")
    static let explorerCdRequest = Notification.Name("explorerCdRequest")
    static let explorerPinRequest = Notification.Name("explorerPinRequest")
}

// MARK: - Resizer (left edge of explorer)

struct ExplorerResizer: View {
    @Binding var width: CGFloat
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Color.black.opacity(0.001)
            .frame(width: 4)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let start = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = width }
                        let next = start + v.translation.width
                        width = max(180, min(600, next))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

// MARK: - Preview

/// Renders the selected file in the most appropriate way:
/// - text/code/markup → monospaced ScrollView with line numbers off
/// - image → NSImage in an Image view
/// - pdf → PDFView from PDFKit
/// - binary → fallback message + "Open in default app" button
struct FilePreview: View {
    let url: URL
    @State private var loadedText: String?
    @State private var textTooLarge = false
    @State private var loadError: String?
    private let maxPreviewBytes = 1_000_000  // 1MB cap on text preview

    private var kind: FileKind { FileKind.detect(url) }

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider().background(Color.white.opacity(0.05))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadIfText() }
        .onChange(of: url) { _, _ in
            loadedText = nil
            textTooLarge = false
            loadError = nil
            loadIfText()
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.iconName)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 9))
                    Text("Open").font(.system(size: 10))
                }
                .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Open in default app (⌘↵ in Finder)")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(BG_DARKEST.opacity(0.4))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .image:        imagePreview
        case .pdf:          pdfPreview
        case .binary:       binaryPreview
        default:            textPreview
        }
    }

    // Image
    private var imagePreview: some View {
        Group {
            if let img = NSImage(contentsOf: url) {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                }
            } else {
                Text("Could not load image")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // PDF
    private var pdfPreview: some View {
        PDFViewRepresentable(url: url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Binary fallback
    private var binaryPreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.3))
            Text("Binary file — preview unavailable")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
            Button("Open in default app") { NSWorkspace.shared.open(url) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Text / source / markup
    @ViewBuilder
    private var textPreview: some View {
        if let err = loadError {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(err).font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if textTooLarge {
            VStack(spacing: 8) {
                Text("File is too large for inline preview (>1MB)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                Button("Open in default app") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text = loadedText {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadIfText() {
        switch kind {
        case .image, .pdf, .binary: return
        default: break
        }
        let target = url
        Task.detached(priority: .userInitiated) {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
                let size = (attrs[.size] as? Int) ?? 0
                if size > 1_000_000 {
                    await MainActor.run {
                        if target == url { textTooLarge = true }
                    }
                    return
                }
                let data = try Data(contentsOf: target)
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                await MainActor.run {
                    if target == url { loadedText = text }
                }
            } catch {
                await MainActor.run {
                    if target == url { loadError = error.localizedDescription }
                }
            }
        }
    }
}

/// PDFKit bridge — SwiftUI doesn't have a native PDFView wrapper.
struct PDFViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .clear
        v.document = PDFDocument(url: url)
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

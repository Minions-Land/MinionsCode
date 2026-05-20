import Foundation
import AppKit

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let fontSizeKey = "minionscode.fontSize"
    private let themeKey = "minionscode.theme"
    private let groupByDirKey = "minionscode.groupByDirectory"
    private let notificationsKey = "minionscode.notifications"
    private let soundKey = "minionscode.sound"

    private let translucentKey = "minionscode.translucent"
    private let historyHorizonKey = "minionscode.historyHorizonDays"
    private let hideEmptyFoldersKey = "minionscode.hideEmptyFolders"
    private let hideInactiveFoldersKey = "minionscode.hideInactiveFolders"
    private let collapseInactivesKey = "minionscode.collapseInactives"
    private let scrollbackKey = "minionscode.scrollbackLines"
    private let explorerCollapsedKey = "minionscode.explorerCollapsed"
    private let explorerWidthKey = "minionscode.explorerWidth"
    private let explorerAutoFollowKey = "minionscode.explorerAutoFollow"
    private let pinnedFoldersKey = "minionscode.pinnedFolders"

    // Claude defaults
    private let defaultModelKey = "minionscode.defaultModel"
    private let defaultEffortKey = "minionscode.defaultEffort"
    private let defaultPermissionModeKey = "minionscode.defaultPermissionMode"
    private let defaultLongContextKey = "minionscode.defaultLongContext"
    private let defaultBypassKey = "minionscode.defaultBypass"

    // Layout
    private let tabBarHeightKey = "minionscode.tabBarHeight"
    private let sidebarWidthKey = "minionscode.sidebarWidth"
    private let terminalAlphaKey = "minionscode.terminalAlpha"
    private let chromeAlphaKey = "minionscode.chromeAlpha"

    var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: fontSizeKey) }
    }

    var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: themeKey) }
    }

    var groupByDirectory: Bool {
        didSet { defaults.set(groupByDirectory, forKey: groupByDirKey) }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: notificationsKey) }
    }

    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: soundKey) }
    }

    var translucentBackground: Bool {
        didSet { defaults.set(translucentBackground, forKey: translucentKey) }
    }

    /// History horizon in days. 7 by default — only sessions modified within
    /// this window appear in the sidebar.
    var historyHorizonDays: Int {
        didSet { defaults.set(historyHorizonDays, forKey: historyHorizonKey) }
    }

    /// Folder-level filters (sidebar)
    var hideEmptyFolders: Bool {
        didSet { defaults.set(hideEmptyFolders, forKey: hideEmptyFoldersKey) }
    }

    var hideInactiveFolders: Bool {
        didSet { defaults.set(hideInactiveFolders, forKey: hideInactiveFoldersKey) }
    }

    var collapseInactivesInFolder: Bool {
        didSet { defaults.set(collapseInactivesInFolder, forKey: collapseInactivesKey) }
    }

    /// Terminal scrollback buffer (in lines). Default 50,000. Larger values
    /// let you scroll further back at the cost of memory — each line is a
    /// few hundred bytes. Applied to NEW terminal sessions; existing tabs
    /// keep their initial scrollback.
    var scrollbackLines: Int {
        didSet { defaults.set(scrollbackLines, forKey: scrollbackKey) }
    }

    /// File explorer panel state.
    var explorerCollapsed: Bool {
        didSet { defaults.set(explorerCollapsed, forKey: explorerCollapsedKey) }
    }
    var explorerWidth: CGFloat {
        didSet { defaults.set(Double(explorerWidth), forKey: explorerWidthKey) }
    }
    /// When true, the explorer's CWD section follows the active terminal's
    /// current directory automatically. When false, the user picked a
    /// folder manually and we leave it alone.
    var explorerAutoFollow: Bool {
        didSet { defaults.set(explorerAutoFollow, forKey: explorerAutoFollowKey) }
    }
    /// Pinned folders shown in the lower section of the explorer.
    var pinnedFolders: [String] {
        didSet { defaults.set(pinnedFolders, forKey: pinnedFoldersKey) }
    }

    // MARK: Claude defaults (used by sidebar resume + new claude tab)

    /// Model alias used by sidebar-launched / new-tab claude. Free-form so
    /// new model names work without recompile (e.g. "claude-opus-4-7").
    var defaultClaudeModel: String {
        didSet { defaults.set(defaultClaudeModel, forKey: defaultModelKey) }
    }
    /// Effort: low / medium / high / xhigh / max — passed to --effort.
    var defaultEffort: String {
        didSet { defaults.set(defaultEffort, forKey: defaultEffortKey) }
    }
    /// Permission mode: default / acceptEdits / auto / bypassPermissions / dontAsk / plan.
    var defaultPermissionMode: String {
        didSet { defaults.set(defaultPermissionMode, forKey: defaultPermissionModeKey) }
    }
    /// Pass --betas context-1m-2025-08-07 by default for sidebar/new claude.
    var defaultLongContext: Bool {
        didSet { defaults.set(defaultLongContext, forKey: defaultLongContextKey) }
    }
    /// Pass --dangerously-skip-permissions on every default launch.
    var defaultDangerouslySkipPermissions: Bool {
        didSet { defaults.set(defaultDangerouslySkipPermissions, forKey: defaultBypassKey) }
    }

    // MARK: Layout

    /// Tab strip height in points. Affects all open terminals.
    var tabBarHeight: CGFloat {
        didSet { defaults.set(Double(tabBarHeight), forKey: tabBarHeightKey) }
    }
    /// Default width of the right session sidebar (in points).
    var sidebarWidth: CGFloat {
        didSet { defaults.set(Double(sidebarWidth), forKey: sidebarWidthKey) }
    }
    /// Alpha multiplier for the terminal cell background (0 = fully
    /// transparent → 1 = opaque).
    var terminalAlpha: Double {
        didSet { defaults.set(terminalAlpha, forKey: terminalAlphaKey) }
    }
    /// Alpha multiplier for the chrome strips (tab bar, sidebars).
    var chromeAlpha: Double {
        didSet { defaults.set(chromeAlpha, forKey: chromeAlphaKey) }
    }

    init() {
        self.fontSize = defaults.object(forKey: fontSizeKey) as? CGFloat ?? 13
        self.theme = Theme(rawValue: defaults.string(forKey: themeKey) ?? "minion") ?? .minion
        self.groupByDirectory = defaults.object(forKey: groupByDirKey) as? Bool ?? true
        self.notificationsEnabled = defaults.object(forKey: notificationsKey) as? Bool ?? true
        self.soundEnabled = defaults.object(forKey: soundKey) as? Bool ?? true
        self.translucentBackground = defaults.object(forKey: translucentKey) as? Bool ?? true
        self.historyHorizonDays = defaults.object(forKey: historyHorizonKey) as? Int ?? 7
        self.hideEmptyFolders = defaults.object(forKey: hideEmptyFoldersKey) as? Bool ?? true
        self.hideInactiveFolders = defaults.object(forKey: hideInactiveFoldersKey) as? Bool ?? false
        self.collapseInactivesInFolder = defaults.object(forKey: collapseInactivesKey) as? Bool ?? true
        self.scrollbackLines = defaults.object(forKey: scrollbackKey) as? Int ?? 50_000
        self.explorerCollapsed = defaults.object(forKey: explorerCollapsedKey) as? Bool ?? true
        self.explorerWidth = CGFloat(defaults.object(forKey: explorerWidthKey) as? Double ?? 280)
        self.explorerAutoFollow = defaults.object(forKey: explorerAutoFollowKey) as? Bool ?? true
        self.pinnedFolders = defaults.object(forKey: pinnedFoldersKey) as? [String] ?? []
        self.defaultClaudeModel = defaults.string(forKey: defaultModelKey) ?? "claude-opus-4-7"
        self.defaultEffort = defaults.string(forKey: defaultEffortKey) ?? "max"
        self.defaultPermissionMode = defaults.string(forKey: defaultPermissionModeKey) ?? "bypassPermissions"
        self.defaultLongContext = defaults.object(forKey: defaultLongContextKey) as? Bool ?? true
        self.defaultDangerouslySkipPermissions = defaults.object(forKey: defaultBypassKey) as? Bool ?? false
        self.tabBarHeight = CGFloat(defaults.object(forKey: tabBarHeightKey) as? Double ?? 40)
        self.sidebarWidth = CGFloat(defaults.object(forKey: sidebarWidthKey) as? Double ?? 320)
        self.terminalAlpha = (defaults.object(forKey: terminalAlphaKey) as? Double) ?? 0.18
        self.chromeAlpha = (defaults.object(forKey: chromeAlphaKey) as? Double) ?? 0.32
    }
}

enum Theme: String, CaseIterable {
    case minion = "minion"
    case midnight = "midnight"
    case lava = "lava"

    var displayName: String {
        switch self {
        case .minion: return "Minion (Black/Gold)"
        case .midnight: return "Midnight"
        case .lava: return "Lava"
        }
    }

    var primary: NSColor {
        switch self {
        case .minion: return NSColor(red: 1.0, green: 0.78, blue: 0.10, alpha: 1)
        case .midnight: return NSColor(red: 0.40, green: 0.80, blue: 1.0, alpha: 1)
        case .lava: return NSColor(red: 1.0, green: 0.40, blue: 0.20, alpha: 1)
        }
    }

    var background: NSColor {
        switch self {
        case .minion: return NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        case .midnight: return NSColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1)
        case .lava: return NSColor(red: 0.07, green: 0.04, blue: 0.05, alpha: 1)
        }
    }

    var foreground: NSColor {
        switch self {
        case .minion: return NSColor(red: 0.93, green: 0.92, blue: 0.85, alpha: 1)
        case .midnight: return NSColor(red: 0.85, green: 0.90, blue: 0.95, alpha: 1)
        case .lava: return NSColor(red: 0.95, green: 0.88, blue: 0.82, alpha: 1)
        }
    }
}

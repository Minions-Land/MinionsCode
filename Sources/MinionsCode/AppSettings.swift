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

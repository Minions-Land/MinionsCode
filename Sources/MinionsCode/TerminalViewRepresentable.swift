import AppKit
import SwiftUI
import SwiftTerm

struct TerminalViewRepresentable: NSViewRepresentable {
    let terminal: TerminalSession

    func makeNSView(context: Context) -> ClickableTerminalView {
        let wrapper = ClickableTerminalView(session: terminal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak wrapper] in
            guard let w = wrapper, w.session?.isReadOnly == false else { return }
            w.window?.makeFirstResponder(w.terminalView)
        }
        return wrapper
    }

    func updateNSView(_ nsView: ClickableTerminalView, context: Context) {}
}

/// Subclass of `LocalProcessTerminalView` that freezes the viewport when the
/// user has scrolled up to read history. SwiftTerm's default behavior is to
/// snap the viewport back to the bottom on every new line — useless when a
/// long Claude session is streaming and you're trying to read older output.
///
/// Strategy:
///   - `scrolled(source:yDisp:)` fires on every yDisp change (user or auto).
///   - We NEVER clear the pin from within `scrolled` — auto-scroll on output
///     would immediately clear it (scrollPosition reads 1.0 after SwiftTerm
///     moves the viewport). Instead, we always restore to the pinned row.
///   - The pin is cleared only by explicit user actions: mouseDown, keyDown
///     (via TerminalKeyMonitor), or user scrolling to the bottom (detected
///     via a local scroll-wheel event monitor).
final class MinionsTerminalView: LocalProcessTerminalView {
    private var pinnedYDisp: Int? = nil
    private var inRestore = false
    private var userScrolling = false
    nonisolated(unsafe) private var scrollMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollWheel(event)
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
    }

    private func handleScrollWheel(_ event: NSEvent) {
        guard event.window === self.window,
              let eventView = window?.contentView?.hitTest(event.locationInWindow),
              eventView === self || eventView.isDescendant(of: self) else { return }
        userScrolling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.userScrolling = false
            if self.scrollPosition >= 0.98 {
                self.pinnedYDisp = nil
            }
        }
    }

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        if inRestore { return }

        if userScrolling {
            if scrollPosition >= 0.98 {
                pinnedYDisp = nil
            } else if pinnedYDisp == nil {
                pinnedYDisp = yDisp
            } else {
                pinnedYDisp = yDisp
            }
            return
        }

        // Not user-initiated. If pinned, restore.
        if let pinned = pinnedYDisp {
            if yDisp != pinned {
                inRestore = true
                scrollTo(row: pinned, notifyAccessibility: false)
                inRestore = false
            }
        }
    }

    func unpin() {
        pinnedYDisp = nil
    }
}

final class ClickableTerminalView: NSView {
    let terminalView: LocalProcessTerminalView
    weak var session: TerminalSession?

    /// Wrapper itself never accepts first-responder status — focus always
    /// belongs to the inner SwiftTerm view, so dictation, IME, and
    /// NSTextInputClient calls reach the right target.
    override var acceptsFirstResponder: Bool { false }
    /// First-mouse: accept the click even if we're not key, so a single
    /// click in an unfocused window both raises the window AND focuses
    /// the terminal — same as Apple Terminal.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(session: TerminalSession) {
        self.session = session
        self.terminalView = session.terminalView
        super.init(frame: .zero)
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Accept dropped files — paths get inserted as quoted strings,
        // matching Apple Terminal / iTerm behavior.
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        terminalView.mouseDown(with: event)
        if session?.isReadOnly == false {
            window?.makeFirstResponder(terminalView)
            // Clicking unpins — user likely wants to interact at the bottom.
            (terminalView as? MinionsTerminalView)?.unpin()
        }
    }

    // MARK: Drag-drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return sender.draggingPasteboard.types?.contains(.fileURL) == true ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty,
              let session = session else { return false }
        // Quote each path, space-separate. The shell will get one or more
        // arguments. Append a trailing space if multiple so the user can
        // continue typing.
        let inserts = urls.map { url -> String in
            let p = url.path
            // Backslash-escape any double quotes inside the path.
            let escaped = p.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        let payload = inserts.joined(separator: " ") + " "
        session.terminalView.send(txt: payload)
        // Make sure the terminal is focused so the user can keep typing.
        if !session.isReadOnly {
            window?.makeFirstResponder(session.terminalView)
        }
        return true
    }
}

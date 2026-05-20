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
/// We can't override `scrollWheel` (it's `public` not `open`), and SwiftTerm's
/// internal `userScrolling` flag is also internal. But `scrolled(source:yDisp:)`
/// IS open, and it fires on every yDisp change — both user-initiated and
/// auto-scroll on output. We use that as the choke point.
///
/// Strategy:
///   - When `scrolled` fires, classify the cause via heuristic on scrollPosition.
///   - If position < 0.98, user is reading history → record yDisp.
///   - If a *later* scrolled callback bumps yDisp past our recorded value
///     (auto-scroll on output), snap back to the recorded row.
///   - When user scrolls back to ~bottom (position >= 0.98), clear.
final class MinionsTerminalView: LocalProcessTerminalView {
    private var pinnedYDisp: Int? = nil
    private var inRestore = false

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        // Re-entrancy guard — our own scrollTo() below will trigger another
        // scrolled callback; we must ignore it to avoid an infinite loop.
        if inRestore { return }

        let pos = scrollPosition  // 0.0 (top) ... 1.0 (bottom)
        let atBottom = pos >= 0.98

        if atBottom {
            // User is back at the bottom — release the pin so future
            // auto-scrolls work normally again.
            pinnedYDisp = nil
            return
        }

        // Not at bottom. Either user just scrolled up, or output
        // auto-scrolled while we had a pin in place.
        if let pinned = pinnedYDisp {
            if yDisp != pinned {
                // Output bumped us — restore.
                inRestore = true
                scrollTo(row: pinned, notifyAccessibility: false)
                inRestore = false
            }
        } else {
            // First scroll-away from the bottom — record the position.
            pinnedYDisp = yDisp
        }
    }

    /// External signal: clear the pin. Called when the user types or clicks,
    /// since they probably want to interact with the prompt at the bottom.
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

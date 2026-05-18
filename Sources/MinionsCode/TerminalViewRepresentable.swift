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

final class ClickableTerminalView: NSView {
    let terminalView: LocalProcessTerminalView
    weak var session: TerminalSession?

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
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // Pass the event to the terminal first (text selection, etc.)
        terminalView.mouseDown(with: event)
        // Synchronously restore focus — no async delay so the caret
        // appears immediately and doesn't race with SwiftTerm's own
        // focus handling.
        if session?.isReadOnly == false {
            window?.makeFirstResponder(terminalView)
        }
    }
}

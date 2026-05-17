import AppKit
import SwiftUI
import SwiftTerm

struct TerminalViewRepresentable: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [terminalView] in
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

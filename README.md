# MinionsCode

A native macOS terminal app for managing Claude Code sessions. Real shell, real terminal, file explorer, session sidebar — all in one window.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6.3-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Why

Claude Code is great. Switching between iTerm tabs, monitoring multiple long-running sessions, hunting for which directory the active session is in, and previewing files without leaving the terminal — less great. MinionsCode collapses that into a single window:

- **Left**: VS Code-style file explorer (auto-follows the active terminal's `cwd`, plus pinned folders)
- **Middle**: Real PTY-backed terminal with multiple tabs
- **Right**: Live sidebar of every Claude Code session on disk — running, idle, finished — with token/cost stats

---

## Features

### Terminal
- **Real PTY** via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — your shell, your prompt, no compromise
- **50,000-line scrollback** by default (configurable in Settings)
- **I-beam blinking cursor** that stays visible regardless of focus state
- **Tab drag-and-drop** reordering
- **Right-click → Move to New Window** to split a session into its own floating window
- **Translucent background** with native macOS vibrancy

### Claude Code integration
- **Session sidebar** — every session in `~/.claude/projects/` is auto-detected and listed with model, tokens, cost
- **Live status** — running sessions show a 🟡 dot; FSEvents-driven updates (no polling lag)
- **Watch mode** — clicking a live session in the sidebar opens a read-only tail of its JSONL (no fork, no duplicate)
- **Default flags** — Opus 4.7, max effort, bypass permissions on every Claude launch
- **Run Claude menu** — full popover for one-off model/effort/permission tweaks
- **Auto-name** — sets a one-line summary on unnamed sessions (extracted from the JSONL via Haiku)
- **Token + cost dashboard** — input / cache read / cache write / output split out, "saved by cache" computed
- **AI-aware search** — literal filter first, fallback to a Haiku one-shot for fuzzy matches

### File Explorer (VS Code-style)
- **Two sections**: CWD (auto-follows active terminal via OSC 7) + Pinned (persistent)
- **Lazy-loaded tree** — folders with thousands of entries don't block the UI
- **Inline preview** at the bottom for the selected file:
  - Text / code / markdown / JSON / YAML / TOML / HTML / CSS / shell — monospaced, selectable
  - Images (PNG, JPG, GIF, HEIC, WebP, SVG, TIFF, BMP) — scrollable
  - PDFs — full PDFKit renderer
  - Binary fallback — size + "Open in default app"
- **Double-click** anything → opens in the system default app
- **Hover actions** — rename / delete (→ Trash, recoverable) / new file
- **1MB cap** on inline text preview; larger files prompt to open externally

### Window behavior
- **Red ×** → minimizes to dock (doesn't kill the app)
- **⌘Q** → quits the process
- **⌘W** → closes active tab; minimizes if no tabs left
- **Dock icon click** → restores the hidden window

---

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘T | New shell tab |
| ⌘N | New window |
| ⌘W | Close active tab (minimize if empty) |
| ⌘Q | Quit |
| ⌘M | Minimize |
| ⌘H | Hide |
| ⌘, | Settings |
| ⌘\ | Toggle session sidebar |
| ⌘⇧E | Toggle file explorer |
| ⌘+ / ⌘- / ⌘0 | Font zoom in / out / reset |
| ⌘1 – ⌘9 | Switch to tab 1–9 |
| ⌘⇧] / ⌘⇧[ | Next / previous tab |
| ⌘F (system) | Toggle full screen (green button) |

Inside the terminal, standard readline shortcuts work as expected:
- ⌘← / ⌘→ → start / end of line (Ctrl-A / Ctrl-E)
- ⌥← / ⌥→ → previous / next word (Esc-B / Esc-F)
- ⌘Backspace → kill to start of line (Ctrl-U)
- ⌥Backspace → kill previous word (Ctrl-W)

---

## Build

```bash
git clone https://github.com/Minions-Land/MinionsCode.git
cd MinionsCode
swift build -c release
bash install.sh --launch        # builds, installs to ~/Applications, launches
```

Requires:
- macOS 14 (Sonoma) or later
- Apple Silicon
- Xcode 16+ command-line tools (`xcode-select --install`)
- A working `claude` binary in `$PATH` (for the Run Claude / Resume features)

`install.sh` accepts `--launch` (or `-r`) to auto-restart any running instance with the fresh build.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Title bar (NSTitlebarAccessoryViewController hosts SwiftUI chrome)  │
├──────────────────────────────────────────────────────────────────────┤
│  Tab bar (drag-to-reorder, status icons per process state)           │
├──────────────┬─────────────────────────────────┬─────────────────────┤
│              │                                 │                     │
│  File        │  Terminal panel                 │  Session sidebar    │
│  Explorer    │  (LocalProcessTerminalView)     │  (parses JSONL,     │
│  (lazy tree, │                                 │   FSEvents-driven)  │
│   preview)   │                                 │                     │
│              │                                 │                     │
└──────────────┴─────────────────────────────────┴─────────────────────┘
```

- **`SessionManager`** — singleton, watches `~/.claude/projects/` + `~/.claude/sessions/` via `FSEventStream`, parses JSONL with size:mtime caching, computes token/cost stats
- **`TerminalSession`** — wraps a `LocalProcessTerminalView` per tab, conforms to `LocalProcessTerminalViewDelegate` for process exit + OSC 7 (cwd updates)
- **`ContentView`** — the SwiftUI root; manages tabs, layout, chrome
- **`FileExplorer`** — left panel: lazy `FileNode` tree, format-aware `FilePreview`
- **`ChromeBridge`** — `@Observable` singleton that ferries state into `NSTitlebarAccessoryViewController` hosts (the SwiftUI `.toolbar` API forces a visual group; we bypass it)

No daemon, no API calls — MinionsCode reads Claude Code's local files directly.

---

## Pricing model

Costs are computed using public Anthropic pricing for Claude 4.x:

| Model | Input | Cache read | Cache write | Output |
|-------|-------|------------|-------------|--------|
| Opus 4.7 | $15/MTok | $1.5/MTok | $18.75/MTok | $75/MTok |
| Sonnet 4.6 | $3/MTok | $0.3/MTok | $3.75/MTok | $15/MTok |
| Haiku 4.5 | $0.8/MTok | $0.08/MTok | $1/MTok | $4/MTok |

Token counts come straight from each session's JSONL `usage` blocks — no inference, no estimation.

---

## Stack

- Swift 6.3, SwiftUI + AppKit
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation
- PDFKit — inline PDF preview
- Apple's `FSEventStream` — directory change watching
- Anthropic SDK (Haiku-only) — auto-naming + AI search fallback

---

## License

MIT

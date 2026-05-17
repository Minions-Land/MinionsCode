# MinionsCode TUI

Cross-platform TUI for browsing and resuming Claude Code sessions. Single binary,
no embedded terminal — selecting a session `exec`s `claude --resume <id>` directly
in your current terminal.

## Build

```bash
./install.sh                          # builds and installs to ~/.local/bin/minionscode
# or:
cargo build --release
cp target/release/minionscode ~/.local/bin/
```

## Run

```bash
minionscode               # launch the TUI
minionscode --list        # non-interactive: print sessions and exit
minionscode --days 7      # only look back 7 days of history (default 30)
```

## Keys (inside the TUI)

**Navigation**
| Key | Action |
|-----|--------|
| `↑ ↓` / `j k` | navigate |
| `g` / `G` | first / last |
| `space` / `tab` | collapse/expand current group |
| `o` / `O` | collapse inactive / expand all groups |
| `T` | toggle grouping by directory |

**Session actions**
| Key | Action |
|-----|--------|
| `⏎` | resume selected session (`claude --resume`) |
| `n` | new claude in selected cwd (defaults) |
| `N` | new claude with options form (model, dangerous, sandbox, verbose, add-dir) |
| `s` | new shell in cwd |
| `r` | rename session (saved to `~/.minionscode/session-names.json`) |

**Search & AI**
| Key | Action |
|-----|--------|
| `/` | literal filter; `⏎` falls back to AI search if nothing matches |
| `\` | force AI search using current filter buffer (calls `claude --print --model haiku`) |
| `A` | auto-name up to 12 unnamed sessions via Haiku |

**Maintenance**
| Key | Action |
|-----|--------|
| `D` | delete junk sessions (tmp/empty) |
| `E` | delete empty sessions |
| `M` | toggle desktop notifications |
| `R` | refresh now |
| `?` | help |
| `q` / `Ctrl-C` | quit |

## Notifications

Fires a desktop notification when a live `claude` session transitions from `busy` →
`idle` after having been busy for ≥ 8s, with a 30s per-session cooldown — same heuristic
as the macOS app, designed to skip short tool turns and only signal completion of a real
conversation. Backend: `notify-send` on Linux, `osascript` on macOS, plus a terminal
bell (`\x07`) on either. Toggle with `M`.

## Layout

Responsive — adapts to terminal size:

- **Wide** (≥ 110 cols): list + detail side-by-side
- **Stacked** (≥ 70 cols, ≥ 24 rows): list on top, compact detail below
- **Narrow** (smaller): list only; selected session summary collapses into the footer

## What it reads

- `~/.claude/sessions/*.json` — live PIDs (`kill -0` to verify)
- `~/.claude/projects/<encoded-cwd>/*.jsonl` — full per-session token usage

Token costs use the same public Anthropic pricing as the macOS app. Parses are
cached by `size:mtime`, so repeated scans are nearly free.

## Refresh strategy

Three layers, designed so status updates feel instant without hammering disk:

1. **File watcher** (`notify` crate — inotify / FSEvents / kqueue). Any change
   under `~/.claude/sessions/` or `~/.claude/projects/` triggers a debounced
   (~180 ms) re-scan.
2. **PID / status sweep** every ~1.5 s. Re-reads only the small `sessions/*.json`
   files and verifies PIDs via `kill -0` — picks up `busy ↔ idle` and
   process-died transitions without touching JSONL.
3. **Fallback full scan** every 30 s (5 s if the watcher failed to attach, e.g.
   on a filesystem without inotify support).

End-to-end, a status change in a live session typically shows up in well under
a second.

## Custom claude path

Set `CLAUDE_BIN=/path/to/claude` to override the auto-discovery (which checks
`/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.claude/local/bin/claude`,
`~/.local/bin/claude`, then `$PATH`).

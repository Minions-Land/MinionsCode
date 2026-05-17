use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::models::SessionInfo;

const MIN_BUSY: Duration = Duration::from_secs(8);
const COOLDOWN: Duration = Duration::from_secs(30);

/// Tracks per-session status transitions and fires a desktop notification only
/// when a main conversation finishes (busy ≥ 8s, 30s cooldown between fires).
/// Same heuristic as the Swift NotificationManager.
pub struct Notifier {
    last_status: HashMap<String, String>,
    busy_start: HashMap<String, Instant>,
    last_fire: HashMap<String, Instant>,
    pub enabled: bool,
}

impl Notifier {
    pub fn new(enabled: bool) -> Self {
        Notifier {
            last_status: HashMap::new(),
            busy_start: HashMap::new(),
            last_fire: HashMap::new(),
            enabled,
        }
    }

    pub fn observe(&mut self, sessions: &[SessionInfo]) {
        if !self.enabled {
            self.last_status = sessions
                .iter()
                .map(|s| (s.id.clone(), s.status.clone()))
                .collect();
            return;
        }
        let now = Instant::now();
        for s in sessions {
            let prev = self.last_status.get(&s.id).cloned();
            let curr = &s.status;

            if prev.as_deref() != Some("busy") && curr == "busy" {
                self.busy_start.insert(s.id.clone(), now);
            }
            if prev.as_deref() == Some("busy") && curr == "idle" && s.is_alive {
                let busy_for = self
                    .busy_start
                    .get(&s.id)
                    .map(|t| now.duration_since(*t))
                    .unwrap_or(Duration::ZERO);
                let cooldown_ok = self
                    .last_fire
                    .get(&s.id)
                    .map(|t| now.duration_since(*t) >= COOLDOWN)
                    .unwrap_or(true);

                if busy_for >= MIN_BUSY && cooldown_ok {
                    fire(&s.name);
                    self.last_fire.insert(s.id.clone(), now);
                }
                self.busy_start.remove(&s.id);
            }
            self.last_status.insert(s.id.clone(), curr.clone());
        }

        // Drop entries for sessions no longer present (avoids unbounded growth).
        let alive: std::collections::HashSet<&str> =
            sessions.iter().map(|s| s.id.as_str()).collect();
        self.last_status
            .retain(|k, _| alive.contains(k.as_str()));
        self.busy_start.retain(|k, _| alive.contains(k.as_str()));
        self.last_fire.retain(|k, _| alive.contains(k.as_str()));
    }
}

#[cfg(target_os = "macos")]
fn fire(name: &str) {
    // Ring terminal bell + native banner via osascript.
    print!("\x07");
    let safe = name.replace('"', "'");
    let _ = Command::new("osascript")
        .arg("-e")
        .arg(format!(
            "display notification \"{}\" with title \"Claude finished\"",
            safe
        ))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

#[cfg(target_os = "linux")]
fn fire(name: &str) {
    // Ring terminal bell + try notify-send.
    print!("\x07");
    use std::io::Write;
    let _ = std::io::stdout().flush();
    let _ = Command::new("notify-send")
        .arg("--app-name=MinionsCode")
        .arg("--icon=utilities-terminal")
        .arg("Claude finished")
        .arg(name)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn fire(_name: &str) {
    print!("\x07");
}

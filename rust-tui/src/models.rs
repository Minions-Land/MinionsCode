use chrono::{DateTime, Local};

#[derive(Debug, Default, Clone, Copy)]
pub struct TokenUsage {
    pub total_input: u64,
    pub total_output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
    pub message_count: u64,
}

impl TokenUsage {
    pub fn cache_hit_rate(&self) -> f64 {
        let total = self.cache_read + self.cache_creation + self.total_input;
        if total == 0 {
            0.0
        } else {
            self.cache_read as f64 / total as f64
        }
    }
}

#[derive(Debug, Clone)]
pub struct SessionInfo {
    pub id: String,
    pub pid: i32,
    pub name: String,
    pub cwd: String,
    pub status: String,
    pub started_at: Option<DateTime<Local>>,
    pub last_activity_at: Option<DateTime<Local>>,
    pub version: String,
    pub model: Option<String>,
    pub usage: TokenUsage,
    pub cost: f64,
    pub is_alive: bool,
}

impl SessionInfo {
    pub fn is_recently_active(&self) -> bool {
        if self.is_alive {
            return true;
        }
        match self.last_activity_at {
            Some(t) => (Local::now() - t).num_seconds() < 3600,
            None => false,
        }
    }
}

/// Public Anthropic pricing per million tokens.
/// Returns (input, output, cache_read, cache_creation) for a given model id.
pub fn pricing_for(model: Option<&str>) -> (f64, f64, f64, f64) {
    let m = model.map(|s| s.to_ascii_lowercase()).unwrap_or_default();
    if m.contains("sonnet") {
        (3.0, 15.0, 0.3, 3.75)
    } else if m.contains("haiku") {
        (0.8, 4.0, 0.08, 1.0)
    } else {
        (15.0, 75.0, 1.5, 18.75)
    }
}

pub fn cost_for(u: &TokenUsage, model: Option<&str>) -> f64 {
    let (pi, po, pcr, pcw) = pricing_for(model);
    (u.total_input as f64) / 1_000_000.0 * pi
        + (u.total_output as f64) / 1_000_000.0 * po
        + (u.cache_read as f64) / 1_000_000.0 * pcr
        + (u.cache_creation as f64) / 1_000_000.0 * pcw
}

pub fn short_path(p: &str) -> String {
    if let Some(home) = dirs::home_dir() {
        let h = home.to_string_lossy().to_string();
        if let Some(rest) = p.strip_prefix(&h) {
            return format!("~{}", rest);
        }
    }
    p.to_string()
}

pub fn model_short(m: Option<&str>) -> &'static str {
    let m = m.map(|s| s.to_ascii_lowercase()).unwrap_or_default();
    if m.contains("opus") {
        "opus"
    } else if m.contains("sonnet") {
        "sonnet"
    } else if m.contains("haiku") {
        "haiku"
    } else {
        "?"
    }
}

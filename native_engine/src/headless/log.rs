//! Dependency-free stderr logging and RFC 3339 timestamps for headless mode.

use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Error = 0,
    Warn = 1,
    Info = 2,
    Debug = 3,
}

impl Level {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "error" => Some(Self::Error),
            "warn" | "warning" => Some(Self::Warn),
            "info" => Some(Self::Info),
            "debug" => Some(Self::Debug),
            _ => None,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Error => "ERROR",
            Self::Warn => "WARN",
            Self::Info => "INFO",
            Self::Debug => "DEBUG",
        }
    }

    fn lowercase(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Warn => "warn",
            Self::Info => "info",
            Self::Debug => "debug",
        }
    }
}

/// stderr rendering: human text (default) or one JSON object per line for
/// log collectors. JSON mode never emits ANSI escapes, even on a terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Text = 0,
    Json = 1,
}

impl Format {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "text" | "plain" => Some(Self::Text),
            "json" | "jsonl" | "ndjson" => Some(Self::Json),
            _ => None,
        }
    }
}

// Level and format are process-wide: one daemon per process, so no logger
// handle.
static LEVEL: AtomicU8 = AtomicU8::new(Level::Info as u8);
static FORMAT: AtomicU8 = AtomicU8::new(Format::Text as u8);

pub fn set_level(level: Level) {
    LEVEL.store(level as u8, Ordering::Relaxed);
}

pub fn set_format(format: Format) {
    FORMAT.store(format as u8, Ordering::Relaxed);
}

fn enabled(level: Level) -> bool {
    level as u8 <= LEVEL.load(Ordering::Relaxed)
}

pub fn log(level: Level, message: impl AsRef<str>) {
    if !enabled(level) {
        return;
    }
    let line = if FORMAT.load(Ordering::Relaxed) == Format::Json as u8 {
        json_line(level, message.as_ref())
    } else {
        text_line(level, message.as_ref())
    };
    eprintln!("{line}");
}

fn text_line(level: Level, message: &str) -> String {
    let style = super::term::stderr_style();
    let label = level.label();
    let painted = match level {
        Level::Error => style.red(label),
        Level::Warn => style.yellow(label),
        Level::Info => style.cyan(label),
        Level::Debug => style.dim(label),
    };
    format!(
        "{} {}{} {}",
        style.dim(&rfc3339_now()),
        painted,
        " ".repeat(5usize.saturating_sub(label.len())),
        message
    )
}

/// Fixed key order (time, level, msg) so collectors need no schema registry.
fn json_line(level: Level, message: &str) -> String {
    format!(
        "{{\"time\":\"{}\",\"level\":\"{}\",\"msg\":\"{}\"}}",
        rfc3339_now(),
        level.lowercase(),
        escape_json(message)
    )
}

fn escape_json(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", control as u32));
            }
            other => out.push(other),
        }
    }
    out
}

pub fn error(message: impl AsRef<str>) {
    log(Level::Error, message);
}

pub fn warn(message: impl AsRef<str>) {
    log(Level::Warn, message);
}

pub fn info(message: impl AsRef<str>) {
    log(Level::Info, message);
}

pub fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

fn rfc3339_now() -> String {
    rfc3339(now_epoch_ms())
}

/// Milliseconds since the Unix epoch -> IMF-fixdate for the HTTP Date header
/// (RFC 7231 section 7.1.1.1), e.g. `Sun, 06 Nov 1994 08:49:37 GMT`.
pub fn http_date(epoch_ms: u64) -> String {
    let epoch_secs = (epoch_ms / 1_000) as i64;
    let days = epoch_secs.div_euclid(86_400);
    let seconds_of_day = epoch_secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    // 1970-01-01 was a Thursday: day 0 -> index 4 in a Sunday-first table.
    let weekday = (days + 4).rem_euclid(7) as usize;
    const WEEKDAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    format!(
        "{}, {:02} {} {:04} {:02}:{:02}:{:02} GMT",
        WEEKDAYS[weekday],
        day,
        MONTHS[(month - 1) as usize],
        year,
        seconds_of_day / 3_600,
        (seconds_of_day % 3_600) / 60,
        seconds_of_day % 60
    )
}

/// Milliseconds since the Unix epoch -> `YYYY-MM-DDTHH:MM:SS.mmmZ` (UTC).
pub fn rfc3339(epoch_ms: u64) -> String {
    let seconds = (epoch_ms / 1000) as i64;
    let millis = epoch_ms % 1000;
    let days = seconds.div_euclid(86_400);
    let seconds_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3600;
    let minute = (seconds_of_day % 3600) / 60;
    let second = seconds_of_day % 60;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        year, month, day, hour, minute, second, millis
    )
}

// Howard Hinnants days-from-civil, inverted. Avoids pulling chrono/time
// into a binary that only needs one timestamp format.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (
        year + if month <= 2 { 1 } else { 0 },
        month as u32,
        day as u32,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3339_formats_known_instants() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(rfc3339(1_700_000_000_000), "2023-11-14T22:13:20.000Z");
        assert_eq!(rfc3339(951_782_400_000), "2000-02-29T00:00:00.000Z");
        assert_eq!(rfc3339(1_609_459_200_123), "2021-01-01T00:00:00.123Z");
    }

    #[test]
    fn level_parser_accepts_common_spellings() {
        assert_eq!(Level::parse("DEBUG"), Some(Level::Debug));
        assert_eq!(Level::parse(" warning "), Some(Level::Warn));
        assert_eq!(Level::parse("trace"), None);
    }

    #[test]
    fn http_date_matches_the_rfc_example() {
        assert_eq!(http_date(0), "Thu, 01 Jan 1970 00:00:00 GMT");
        assert_eq!(http_date(784_111_777_123), "Sun, 06 Nov 1994 08:49:37 GMT");
        assert_eq!(http_date(951_782_400_000), "Tue, 29 Feb 2000 00:00:00 GMT");
        assert_eq!(
            http_date(1_700_000_000_000),
            "Tue, 14 Nov 2023 22:13:20 GMT"
        );
    }

    #[test]
    fn format_parser_accepts_aliases() {
        assert_eq!(Format::parse("JSON"), Some(Format::Json));
        assert_eq!(Format::parse(" ndjson "), Some(Format::Json));
        assert_eq!(Format::parse("text"), Some(Format::Text));
        assert_eq!(Format::parse("xml"), None);
    }

    #[test]
    fn json_lines_escape_quotes_and_control_characters() {
        let line = json_line(Level::Warn, "a \"b\" \\ c\n\td\u{1}");
        assert!(line.starts_with("{\"time\":\""), "{line}");
        assert!(line.contains("\"level\":\"warn\""), "{line}");
        // The message must contain no raw newline or tab: one record per line.
        let record: serde_json::Value = serde_json::from_str(&line).expect("valid json");
        assert_eq!(record["level"], "warn");
        assert_eq!(record["msg"], "a \"b\" \\ c\n\td\u{1}");
        assert_eq!(line.matches('\n').count(), 0, "{line}");
    }
}

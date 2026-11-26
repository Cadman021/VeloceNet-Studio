//! Human-readable snapshot tables for terminals.
//!
//! This module is deliberately separate from JSON/NDJSON: machines get the
//! exact same schema as the desktop app, while an operator gets one line per
//! target, stable columns, and colour-coded status.

use super::term::Style;
use super::{Snapshot, VERSION};
use crate::stats::{TargetStats, TargetStatus};

const STATUS_WIDTH: usize = 8;
const MAX_NAME_WIDTH: usize = 22;
const MAX_PROBE_WIDTH: usize = 28;
const HTTP_WIDTH: usize = 16;
const DETAIL_WIDTH: usize = 34;

pub fn render(snapshot: &Snapshot, style: Style) -> String {
    let show_http = snapshot.targets.iter().any(|target| {
        target.http_status.is_some()
            || target.cert_days_left.is_some()
            || matches!(target.protocol.as_str(), "HTTP" | "HTTPS")
    });
    let show_detail = snapshot
        .targets
        .iter()
        .any(|target| target.last_error.is_some() || target.tcp_fallback || target.stale);
    let name_width = snapshot
        .targets
        .iter()
        .map(|target| target.name.chars().count())
        .max()
        .unwrap_or(6)
        .clamp(6, MAX_NAME_WIDTH);
    let probe_width = snapshot
        .targets
        .iter()
        .map(|target| probe_text(target).chars().count())
        .max()
        .unwrap_or(10)
        .clamp(10, MAX_PROBE_WIDTH);

    let mut table_width =
        STATUS_WIDTH + 2 + name_width + 2 + probe_width + 2 + 10 + 2 + 9 + 2 + 7 + 2 + 9;
    if show_http {
        table_width += 2 + HTTP_WIDTH;
    }
    if show_detail {
        table_width += 2 + DETAIL_WIDTH;
    }

    let mut out = String::new();
    out.push_str(&style.dim(&"-".repeat(table_width)));
    out.push('\n');
    out.push_str(&format!(
        "{} {}  {}",
        style.bold("NetStudio Headless"),
        style.dim(&format!("v{VERSION}")),
        style.dim(&snapshot.time)
    ));
    out.push('\n');

    out.push_str(&style.dim(&format!(
        "{:<STATUS_WIDTH$}  {:<name_width$}  {:<probe_width$}  {:>10}  {:>9}  {:>7}  {:>9}",
        "STATUS", "TARGET", "PROBE", "RTT", "JITTER", "LOSS", "OK/SENT"
    )));
    if show_http {
        out.push_str(&format!("  {:>HTTP_WIDTH$}", "HTTP/CERT"));
    }
    if show_detail {
        out.push_str(&format!("  {:<DETAIL_WIDTH$}", "DETAIL"));
    }
    out.push('\n');
    out.push_str(&style.dim(&"-".repeat(table_width)));
    out.push('\n');

    for target in &snapshot.targets {
        let status = status_cell(target.status, style);
        let name = clip(&target.name, name_width);
        let name_pad = name_width.saturating_sub(name.chars().count());
        let probe = clip(&probe_text(target), probe_width);
        let probe_pad = probe_width.saturating_sub(probe.chars().count());
        out.push_str(&format!(
            "{status}  {}{}  {}{}  {:>10}  {:>9}  {:>7}  {:>9}",
            style.bold(&name),
            " ".repeat(name_pad),
            style.dim(&probe),
            " ".repeat(probe_pad),
            rtt_text(target),
            jitter_text(target),
            loss_text(target),
            count_text(target)
        ));
        if show_http {
            out.push_str("  ");
            out.push_str(&http_cell(target, style));
        }
        if show_detail {
            out.push_str("  ");
            out.push_str(&detail_cell(target, style));
        }
        out.push('\n');
    }

    out.push_str(&summary_line(snapshot, style));
    out.push('\n');
    out
}

fn status_label(status: TargetStatus) -> &'static str {
    match status {
        TargetStatus::Pending => "PENDING",
        TargetStatus::Online => "ONLINE",
        TargetStatus::Degraded => "DEGRADED",
        TargetStatus::Offline => "OFFLINE",
    }
}

fn status_cell(status: TargetStatus, style: Style) -> String {
    let label = status_label(status);
    let painted = match status {
        TargetStatus::Online => style.green(label),
        TargetStatus::Degraded => style.yellow(label),
        TargetStatus::Offline => style.red(label),
        TargetStatus::Pending => style.dim(label),
    };
    format!(
        "{painted}{}",
        " ".repeat(STATUS_WIDTH.saturating_sub(label.len()))
    )
}

fn probe_text(target: &TargetStats) -> String {
    let host = if target.host.contains(':') && !target.host.starts_with('[') {
        format!("[{}]", target.host)
    } else {
        target.host.clone()
    };
    format!("{} {}:{}", target.protocol, host, target.port)
}

fn rtt_text(target: &TargetStats) -> String {
    if target.sent_count == 0 || target.last_rtt_ms < 0.0 {
        "-".to_string()
    } else {
        format!("{:.2} ms", target.last_rtt_ms)
    }
}

fn jitter_text(target: &TargetStats) -> String {
    if target.received_count == 0 {
        "-".to_string()
    } else {
        format!("{:.2} ms", target.jitter_ms)
    }
}

fn loss_text(target: &TargetStats) -> String {
    if target.sent_count == 0 {
        "-".to_string()
    } else {
        format!("{:.1}%", target.loss_rate)
    }
}

fn count_text(target: &TargetStats) -> String {
    format!("{}/{}", target.received_count, target.sent_count)
}

fn http_cell(target: &TargetStats, style: Style) -> String {
    let raw = match (target.http_status, target.cert_days_left) {
        (Some(code), Some(days)) => format!("{code} | {days}d"),
        (Some(code), None) => code.to_string(),
        (None, Some(days)) => format!("{days}d"),
        (None, None) => "-".to_string(),
    };
    let painted = if raw == "-" {
        style.dim(&raw)
    } else if target.http_status.is_some_and(|code| code >= 400)
        || target.cert_days_left.is_some_and(|days| days <= 0)
    {
        style.red(&raw)
    } else if target.cert_days_left.is_some_and(|days| days < 30) {
        style.yellow(&raw)
    } else {
        style.green(&raw)
    };
    format!(
        "{}{painted}",
        " ".repeat(HTTP_WIDTH.saturating_sub(raw.chars().count()))
    )
}

fn age_text(age_ms: Option<u64>) -> String {
    let seconds = age_ms.unwrap_or(0) / 1_000;
    if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3_600 {
        format!("{}m{:02}s", seconds / 60, seconds % 60)
    } else {
        format!("{}h{:02}m", seconds / 3_600, (seconds % 3_600) / 60)
    }
}

fn detail_text(target: &TargetStats) -> Option<String> {
    let mut notes = Vec::new();
    if target.stale {
        notes.push(format!("stale {}", age_text(target.last_sample_age_ms)));
    }
    if target.tcp_fallback {
        notes.push("tcp fallback".to_string());
    }
    if let Some(error) = &target.last_error {
        let kind = target
            .last_error_kind
            .map(|kind| kind.as_str())
            .unwrap_or("error");
        notes.push(format!("{kind}: {error}"));
    }
    if notes.is_empty() {
        None
    } else {
        Some(notes.join(" | "))
    }
}

fn detail_cell(target: &TargetStats, style: Style) -> String {
    let Some(raw) = detail_text(target) else {
        return " ".repeat(DETAIL_WIDTH);
    };
    let clipped = clip(&raw, DETAIL_WIDTH);
    let painted = if target.last_error.is_some() {
        style.red(&clipped)
    } else if target.stale || target.tcp_fallback {
        style.yellow(&clipped)
    } else {
        style.dim(&clipped)
    };
    format!(
        "{painted}{}",
        " ".repeat(DETAIL_WIDTH.saturating_sub(clipped.chars().count()))
    )
}

fn summary_line(snapshot: &Snapshot, style: Style) -> String {
    let summary = &snapshot.summary;
    let online = if summary.online > 0 {
        style.green(&format!("{} online", summary.online))
    } else {
        style.dim("0 online")
    };
    let degraded = if summary.degraded > 0 {
        style.yellow(&format!("{} degraded", summary.degraded))
    } else {
        style.dim("0 degraded")
    };
    let offline = if summary.offline > 0 {
        style.red(&format!("{} offline", summary.offline))
    } else {
        style.dim("0 offline")
    };
    let pending = style.dim(&format!("{} pending", summary.pending));
    let stale = if summary.stale > 0 {
        style.yellow(&format!("{} stale", summary.stale))
    } else {
        style.dim("0 stale")
    };
    let down = if summary.down > 0 {
        style.red(&format!("{} down", summary.down))
    } else {
        style.green("0 down")
    };
    [online, degraded, offline, pending, stale, down].join("  |  ")
}

fn clip(value: &str, width: usize) -> String {
    if value.chars().count() <= width {
        return value.to_string();
    }
    let mut clipped: String = value.chars().take(width.saturating_sub(1)).collect();
    clipped.push('~');
    clipped
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(
        id: u32,
        name: &str,
        status: TargetStatus,
        sent: u64,
        received: u64,
        rtt: f64,
    ) -> TargetStats {
        TargetStats {
            id,
            name: name.to_string(),
            host: "127.0.0.1".to_string(),
            port: 80,
            protocol: "TCP".to_string(),
            status,
            sent_count: sent,
            received_count: received,
            lost_count: sent.saturating_sub(received),
            loss_rate: if sent == 0 {
                0.0
            } else {
                (sent - received) as f64 * 100.0 / sent as f64
            },
            last_rtt_ms: rtt,
            min_rtt_ms: rtt.max(0.0),
            max_rtt_ms: rtt.max(0.0),
            avg_rtt_ms: rtt.max(0.0),
            jitter_ms: 0.25,
            history: vec![],
            last_checked_epoch_ms: 0,
            http_status: None,
            cert_days_left: None,
            last_error: None,
            last_error_kind: None,
            tcp_fallback: false,
            stale: false,
            last_sample_age_ms: Some(0),
            stale_after_ms: 3_500,
        }
    }

    #[test]
    fn renders_a_readable_table_without_json_noise() {
        let snapshot = Snapshot::new(vec![
            target(1, "Primary", TargetStatus::Online, 10, 10, 1.234),
            target(2, "Backup", TargetStatus::Offline, 10, 0, -1.0),
        ]);
        let text = render(&snapshot, Style::plain());

        assert!(text.contains("ONLINE"));
        assert!(text.contains("OFFLINE"));
        assert!(text.contains("Primary"));
        assert!(text.contains("1.23 ms"));
        assert!(text.contains("0/10"));
        assert!(text.contains("1 online"));
        assert!(text.contains("1 offline"));
        assert!(!text.contains("\"schema\""));
        assert!(!text.contains("history"));
    }

    #[test]
    fn colours_statuses_only_when_enabled() {
        let snapshot = Snapshot::new(vec![target(1, "Primary", TargetStatus::Online, 1, 1, 2.0)]);
        let colored = render(&snapshot, Style::colored());
        assert!(colored.contains("\x1b[32mONLINE\x1b[0m"));
        assert!(!render(&snapshot, Style::plain()).contains("\x1b["));
    }

    #[test]
    fn http_and_certificate_column_appears_for_http_targets() {
        let mut stats = target(1, "API", TargetStatus::Online, 1, 1, 3.0);
        stats.protocol = "HTTPS".to_string();
        stats.http_status = Some(200);
        stats.cert_days_left = Some(42);
        let text = render(&Snapshot::new(vec![stats]), Style::plain());
        assert!(text.contains("HTTP/CERT"));
        assert!(text.contains("200 | 42d"));
    }

    #[test]
    fn detail_column_shows_error_kind_and_staleness() {
        let mut failed = target(1, "DNS", TargetStatus::Offline, 3, 0, -1.0);
        failed.last_error = Some("DNS resolution failed: no such host".to_string());
        failed.last_error_kind = Some(crate::stats::ProbeErrorKind::Dns);
        let mut stale = target(2, "Old", TargetStatus::Online, 1, 1, 5.0);
        stale.stale = true;
        stale.last_sample_age_ms = Some(12_000);
        let text = render(&Snapshot::new(vec![failed, stale]), Style::plain());
        assert!(text.contains("DETAIL"));
        assert!(text.contains("dns: DNS resolution failed"));
        assert!(text.contains("stale 12s"));
        assert!(text.contains("1 stale"));
    }

    #[test]
    fn long_names_are_clipped_to_keep_columns_aligned() {
        let snapshot = Snapshot::new(vec![target(
            1,
            "a-very-long-target-name-that-does-not-fit",
            TargetStatus::Online,
            1,
            1,
            1.0,
        )]);
        let text = render(&snapshot, Style::plain());
        assert!(text.contains("a-very-long-target-na~"));
    }
}

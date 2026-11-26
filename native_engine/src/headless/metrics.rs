//! Prometheus text exposition for the headless daemon.

use std::fmt::Write as _;

use crate::stats::{TargetStats, TargetStatus};

pub fn render(stats: &[TargetStats], version: &str) -> String {
    let mut out = String::with_capacity(4_096);
    let _ = writeln!(
        out,
        "# HELP netstudio_build_info Headless engine build information."
    );
    let _ = writeln!(out, "# TYPE netstudio_build_info gauge");
    let _ = writeln!(
        out,
        "netstudio_build_info{{version=\"{}\"}} 1",
        escape_label(version)
    );

    gauge_family(
        &mut out,
        "netstudio_target_info",
        "Static labels for a configured target.",
        stats,
        |_| 1.0,
    );
    gauge_family(
        &mut out,
        "netstudio_target_up",
        "1 when the most recent probe succeeded, 0 otherwise.",
        stats,
        up_value,
    );
    gauge_family(
        &mut out,
        "netstudio_target_status",
        "0 pending, 1 online, 2 degraded, 3 offline.",
        stats,
        status_value,
    );
    counter_family(
        &mut out,
        "netstudio_target_sent_total",
        "Probes sent since the process started.",
        stats,
        |target| target.sent_count,
    );
    counter_family(
        &mut out,
        "netstudio_target_received_total",
        "Probes answered since the process started.",
        stats,
        |target| target.received_count,
    );
    counter_family(
        &mut out,
        "netstudio_target_lost_total",
        "Probes without a reply since the process started.",
        stats,
        |target| target.lost_count,
    );
    gauge_family(
        &mut out,
        "netstudio_target_loss_rate_percent",
        "Lifetime packet loss percentage.",
        stats,
        |target| target.loss_rate,
    );
    gauge_family(
        &mut out,
        "netstudio_target_rtt_last_ms",
        "Most recent round-trip time in milliseconds (-1 means down).",
        stats,
        |target| target.last_rtt_ms,
    );
    gauge_family(
        &mut out,
        "netstudio_target_rtt_min_ms",
        "Minimum successful round-trip time in milliseconds.",
        stats,
        |target| target.min_rtt_ms,
    );
    gauge_family(
        &mut out,
        "netstudio_target_rtt_max_ms",
        "Maximum successful round-trip time in milliseconds.",
        stats,
        |target| target.max_rtt_ms,
    );
    gauge_family(
        &mut out,
        "netstudio_target_rtt_avg_ms",
        "Mean successful round-trip time in milliseconds.",
        stats,
        |target| target.avg_rtt_ms,
    );
    gauge_family(
        &mut out,
        "netstudio_target_jitter_ms",
        "RFC 3550 jitter estimate in milliseconds.",
        stats,
        |target| target.jitter_ms,
    );
    gauge_family(
        &mut out,
        "netstudio_target_last_check_timestamp_seconds",
        "Unix timestamp of the latest snapshot in seconds.",
        stats,
        |target| target.last_checked_epoch_ms as f64 / 1_000.0,
    );

    let _ = writeln!(
        out,
        "# HELP netstudio_target_http_status_code Latest HTTP status code.",
    );
    let _ = writeln!(out, "# TYPE netstudio_target_http_status_code gauge");
    for target in stats {
        if let Some(code) = target.http_status {
            let _ = writeln!(
                out,
                "netstudio_target_http_status_code{{{}}} {code}",
                labels(target)
            );
        }
    }

    let _ = writeln!(
        out,
        "# HELP netstudio_target_cert_days_left Days until the TLS certificate expires.",
    );
    let _ = writeln!(out, "# TYPE netstudio_target_cert_days_left gauge");
    for target in stats {
        if let Some(days) = target.cert_days_left {
            let _ = writeln!(
                out,
                "netstudio_target_cert_days_left{{{}}} {days}",
                labels(target)
            );
        }
    }
    out
}

fn gauge_family(
    out: &mut String,
    name: &str,
    help: &str,
    stats: &[TargetStats],
    value: impl Fn(&TargetStats) -> f64,
) {
    let _ = writeln!(out, "# HELP {name} {help}");
    let _ = writeln!(out, "# TYPE {name} gauge");
    for target in stats {
        let _ = writeln!(
            out,
            "{name}{{{}}} {}",
            labels(target),
            number(value(target))
        );
    }
}

fn number(value: f64) -> String {
    if value.is_finite() && value.fract() == 0.0 {
        format!("{value:.0}")
    } else {
        format!("{value:.3}")
    }
}

fn counter_family(
    out: &mut String,
    name: &str,
    help: &str,
    stats: &[TargetStats],
    value: impl Fn(&TargetStats) -> u64,
) {
    let _ = writeln!(out, "# HELP {name} {help}");
    let _ = writeln!(out, "# TYPE {name} counter");
    for target in stats {
        let _ = writeln!(out, "{name}{{{}}} {}", labels(target), value(target));
    }
}

fn labels(target: &TargetStats) -> String {
    format!(
        "id=\"{}\",name=\"{}\",host=\"{}\",port=\"{}\",protocol=\"{}\"",
        target.id,
        escape_label(&target.name),
        escape_label(&target.host),
        target.port,
        escape_label(&target.protocol),
    )
}

fn up_value(target: &TargetStats) -> f64 {
    if target.sent_count > 0 && target.last_rtt_ms >= 0.0 {
        1.0
    } else {
        0.0
    }
}

fn status_value(target: &TargetStats) -> f64 {
    match target.status {
        TargetStatus::Pending => 0.0,
        TargetStatus::Online => 1.0,
        TargetStatus::Degraded => 2.0,
        TargetStatus::Offline => 3.0,
    }
}

pub(crate) fn escape_label(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            c if c == char::from(92u8) => out.push_str(r"\\"),
            c if c == char::from(34u8) => out.push_str(r#"\""#),
            c if c == char::from(10u8) => out.push_str(r"\n"),
            c if c == char::from(13u8) => out.push(char::from(32u8)),
            _ => out.push(character),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::TargetMetricTracker;

    fn sample() -> TargetStats {
        let mut tracker = TargetMetricTracker::new(
            1,
            "API".to_string(),
            "127.0.0.1".to_string(),
            80,
            "TCP".to_string(),
        );
        tracker.record_sample(true, 12.5, Some(204), Some(9));
        tracker.snapshot()
    }

    #[test]
    fn renders_core_families_and_labels() {
        let text = render(&[sample()], "1.6.0");
        assert!(text.contains("netstudio_build_info{version=\"1.6.0\"} 1"));
        assert!(text.contains(
            "netstudio_target_status{id=\"1\",name=\"API\",host=\"127.0.0.1\",port=\"80\",protocol=\"TCP\"} 1"
        ));
        assert!(text.contains(
            "netstudio_target_sent_total{id=\"1\",name=\"API\",host=\"127.0.0.1\",port=\"80\",protocol=\"TCP\"} 1"
        ));
        assert!(text.contains("netstudio_target_http_status_code"));
        assert!(text.contains("netstudio_target_http_status_code{id=\"1\""));
        assert!(text.contains(" 204"));
        assert!(text.contains("netstudio_target_cert_days_left"));
    }

    #[test]
    fn escapes_label_values() {
        assert_eq!(escape_label("a\"b"), r#"a\"b"#);
        assert_eq!(escape_label(r"a\b"), "a\\\\b");
    }
}

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
    // Absent (rather than 0) until the first sample: a target nobody has
    // probed yet is not "down", and alert rules on up == 0 must not fire on
    // daemon startup or on a target whose interval is longer than the scrape.
    gauge_family_if(
        &mut out,
        "netstudio_target_up",
        "1 when the most recent probe succeeded, 0 when it failed (absent until the first sample).",
        stats,
        |target| target.sent_count > 0,
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
        "Unix timestamp when the latest probe sample completed.",
        stats,
        |target| target.last_checked_epoch_ms as f64 / 1_000.0,
    );
    gauge_family(
        &mut out,
        "netstudio_target_last_success_timestamp_seconds",
        "Unix timestamp of the last successful probe (-1 before the first success).",
        stats,
        |target| {
            if target.last_success_epoch_ms == 0 {
                -1.0
            } else {
                target.last_success_epoch_ms as f64 / 1_000.0
            }
        },
    );
    gauge_family(
        &mut out,
        "netstudio_target_last_sample_age_seconds",
        "Age of the latest probe sample in seconds (-1 before the first sample).",
        stats,
        |target| {
            target
                .last_sample_age_ms
                .map_or(-1.0, |age_ms| age_ms as f64 / 1_000.0)
        },
    );
    gauge_family(
        &mut out,
        "netstudio_target_stale",
        "1 when no fresh sample arrived within 2 x interval + timeout.",
        stats,
        |target| if target.stale { 1.0 } else { 0.0 },
    );
    gauge_family(
        &mut out,
        "netstudio_target_tcp_fallback",
        "1 when the latest ICMP probe used the TCP fallback.",
        stats,
        |target| if target.tcp_fallback { 1.0 } else { 0.0 },
    );
    gauge_family(
        &mut out,
        "netstudio_target_muted",
        "1 when the target is muted in the app (still probed, not alert-worthy).",
        stats,
        |target| if target.muted { 1.0 } else { 0.0 },
    );

    let _ = writeln!(
        out,
        "# HELP netstudio_target_error_info Latest probe failure kind (one series per failed target).",
    );
    let _ = writeln!(out, "# TYPE netstudio_target_error_info gauge");
    for target in stats {
        if let Some(kind) = target.last_error_kind {
            let _ = writeln!(
                out,
                "netstudio_target_error_info{{{},kind=\"{}\"}} 1",
                labels(target),
                escape_label(kind.as_str())
            );
        }
    }

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
    gauge_family_if(out, name, help, stats, |_| true, value);
}

/// Same as gauge_family, but only targets accepted by `visible` get a series.
fn gauge_family_if(
    out: &mut String,
    name: &str,
    help: &str,
    stats: &[TargetStats],
    visible: impl Fn(&TargetStats) -> bool,
    value: impl Fn(&TargetStats) -> f64,
) {
    let _ = writeln!(out, "# HELP {name} {help}");
    let _ = writeln!(out, "# TYPE {name} gauge");
    for target in stats.iter().filter(|target| visible(target)) {
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
        "id=\"{}\",name=\"{}\",host=\"{}\",port=\"{}\",protocol=\"{}\",group=\"{}\"",
        target.id,
        escape_label(&target.name),
        escape_label(&target.host),
        target.port,
        escape_label(&target.protocol),
        escape_label(&target.group),
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
            "netstudio_target_status{id=\"1\",name=\"API\",host=\"127.0.0.1\",port=\"80\",protocol=\"TCP\",group=\"\"} 1"
        ));
        assert!(text.contains(
            "netstudio_target_sent_total{id=\"1\",name=\"API\",host=\"127.0.0.1\",port=\"80\",protocol=\"TCP\",group=\"\"} 1"
        ));
        assert!(text.contains("netstudio_target_http_status_code"));
        assert!(text.contains("netstudio_target_http_status_code{id=\"1\""));
        assert!(text.contains(" 204"));
        assert!(text.contains("netstudio_target_cert_days_left"));
        assert!(text.contains("netstudio_target_stale"));
        assert!(text.contains("netstudio_target_last_sample_age_seconds"));
        assert!(text.contains("netstudio_target_last_success_timestamp_seconds"));
        assert!(text.contains("netstudio_target_tcp_fallback"));
    }

    #[test]
    fn last_success_is_minus_one_until_a_probe_answers() {
        let mut pending = TargetMetricTracker::new(
            3,
            "Pending".to_string(),
            "127.0.0.1".to_string(),
            80,
            "TCP".to_string(),
        );
        let text = render(&[pending.snapshot()], "1.6.0");
        assert!(
            text.contains("netstudio_target_last_success_timestamp_seconds{id=\"3\",")
                && text.contains("} -1\n"),
            "{text}"
        );

        pending.record_sample(false, -1.0, None, None);
        let failed = render(&[pending.snapshot()], "1.6.0");
        // A failure moves the check timestamp but leaves last_success at -1.
        assert!(
            failed.contains("netstudio_target_last_success_timestamp_seconds{id=\"3\",")
                && failed.contains("} -1\n"),
            "{failed}"
        );

        pending.record_sample(true, 1.0, None, None);
        let ok = render(&[pending.snapshot()], "1.6.0");
        assert!(
            !ok.contains("} -1\n") || ok.contains("last_sample_age"),
            "{ok}"
        );
        let line = ok
            .lines()
            .find(|line| line.starts_with("netstudio_target_last_success_timestamp_seconds{"))
            .expect("series");
        let value: f64 = line
            .rsplit(' ')
            .next()
            .expect("value")
            .parse()
            .expect("number");
        assert!(value > 1_600_000_000.0, "{line}");
    }

    #[test]
    fn renders_error_kind_without_the_raw_message() {
        let mut tracker = TargetMetricTracker::new(
            2,
            "Broken".to_string(),
            "127.0.0.1".to_string(),
            80,
            "TCP".to_string(),
        );
        tracker.record_probe(crate::stats::ProbeSample {
            success: false,
            rtt_ms: -1.0,
            http_status: None,
            cert_days_left: None,
            error_kind: Some(crate::stats::ProbeErrorKind::Refused),
            error: Some("Connect failed: connection refused".to_string()),
            tcp_fallback: true,
        });
        let text = render(&[tracker.snapshot()], "1.6.0");
        assert!(text.contains("netstudio_target_error_info{id=\"2\","));
        assert!(text.contains("kind=\"refused\""));
        assert!(!text.contains("connection refused"));
        assert!(text.contains("netstudio_target_tcp_fallback{id=\"2\","));
    }

    #[test]
    fn pending_targets_have_no_up_series() {
        let target = TargetMetricTracker::new(
            3,
            "Pending".to_string(),
            "127.0.0.1".to_string(),
            80,
            "TCP".to_string(),
        )
        .snapshot();
        let text = render(&[target], "1.6.0");
        // The family header stays, the series does not: nothing has been
        // probed yet, so "down" would be a lie.
        assert!(text.contains("# HELP netstudio_target_up "));
        assert!(!text.contains("netstudio_target_up{"));
        // The pending status itself stays visible to dashboards.
        assert!(text.contains("netstudio_target_status{id=\"3\""));
    }

    #[test]
    fn group_and_mute_become_a_label_and_a_gauge() {
        let mut tracker = TargetMetricTracker::new(
            4,
            "Edge".to_string(),
            "127.0.0.1".to_string(),
            80,
            "TCP".to_string(),
        )
        .with_organization("edge".to_string(), true);
        tracker.record_sample(false, -1.0, None, None);
        let text = render(&[tracker.snapshot()], "1.6.0");
        assert!(text.contains("group=\"edge\""));
        assert!(text.lines().any(|line| {
            line.starts_with("netstudio_target_muted{id=\"4\"") && line.ends_with(" 1")
        }));
        assert!(text.lines().any(|line| {
            line.starts_with("netstudio_target_up{id=\"4\"") && line.ends_with(" 0")
        }));
    }

    #[test]
    fn escapes_label_values() {
        assert_eq!(escape_label("a\"b"), r#"a\"b"#);
        assert_eq!(escape_label(r"a\b"), "a\\\\b");
    }
}

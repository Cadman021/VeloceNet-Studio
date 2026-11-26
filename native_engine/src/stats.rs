use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU32, Ordering};

const MAX_HISTORY_SAMPLES: usize = 40;
const MAX_ERROR_CHARS: usize = 160;

/// Process-wide alert thresholds (defaults match the previous hardcoded
/// behavior). Configured from Dart via `netstudio_set_alert_thresholds`;
/// per-target config would cost an FFI signature change for zero practical
/// gain (operators tune these globally).
static OFFLINE_AFTER: AtomicU32 = AtomicU32::new(3);
static RECOVER_AFTER: AtomicU32 = AtomicU32::new(2);

/// Sets the alert thresholds (each clamped to 1..=20; 0 keeps current).
pub fn set_alert_thresholds(offline_after: u32, recover_after: u32) {
    if offline_after >= 1 {
        OFFLINE_AFTER.store(offline_after.min(20), Ordering::SeqCst);
    }
    if recover_after >= 1 {
        RECOVER_AFTER.store(recover_after.min(20), Ordering::SeqCst);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TargetStatus {
    Pending,
    Online,
    Degraded,
    Offline,
}

/// Why the latest probe failed. Kept as a small closed set so operators (and
/// alert rules) can distinguish DNS, routing and application failures without
/// parsing human-readable error strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProbeErrorKind {
    Dns,
    Timeout,
    Refused,
    Unreachable,
    IcmpUnavailable,
    Tls,
    Http,
    Other,
}

impl ProbeErrorKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Dns => "dns",
            Self::Timeout => "timeout",
            Self::Refused => "refused",
            Self::Unreachable => "unreachable",
            Self::IcmpUnavailable => "icmp_unavailable",
            Self::Tls => "tls",
            Self::Http => "http",
            Self::Other => "other",
        }
    }
}

/// One probe result as handed to the tracker. Keeping this separate from
/// ProbeResult lets stats stay independent of the async probe module.
#[derive(Debug, Clone)]
pub struct ProbeSample {
    pub success: bool,
    pub rtt_ms: f64,
    pub http_status: Option<u16>,
    pub cert_days_left: Option<i64>,
    pub error_kind: Option<ProbeErrorKind>,
    pub error: Option<String>,
    pub tcp_fallback: bool,
}

impl ProbeSample {
    pub fn success(rtt_ms: f64, http_status: Option<u16>, cert_days_left: Option<i64>) -> Self {
        Self {
            success: true,
            rtt_ms,
            http_status,
            cert_days_left,
            error_kind: None,
            error: None,
            tcp_fallback: false,
        }
    }
}

/// Shortens and flattens a probe error before it leaves the engine: no
/// newlines/control characters, no multi-line stack traces, and a hard cap so
/// an OS message can never bloat every status scrape. Secrets are never part
/// of these messages (probe errors contain host/port and OS text only).
pub fn sanitize_error(message: &str) -> String {
    let flattened: String = message
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect();
    let mut out = String::with_capacity(flattened.len().min(MAX_ERROR_CHARS));
    for (index, word) in flattened.split_whitespace().enumerate() {
        if index > 0 {
            out.push(' ');
        }
        out.push_str(word);
    }
    if out.is_empty() {
        return "probe failed".to_string();
    }
    if out.chars().count() > MAX_ERROR_CHARS {
        out = out.chars().take(MAX_ERROR_CHARS - 3).collect();
        out.push_str("...");
    }
    out
}

pub(crate) fn now_epoch_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TargetStats {
    pub id: u32,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub protocol: String,
    pub status: TargetStatus,
    pub sent_count: u64,
    pub received_count: u64,
    pub lost_count: u64,
    pub loss_rate: f64,
    pub last_rtt_ms: f64,
    pub min_rtt_ms: f64,
    pub max_rtt_ms: f64,
    pub avg_rtt_ms: f64,
    pub jitter_ms: f64,
    pub history: Vec<f64>,
    pub last_checked_epoch_ms: u64,
    /// HTTP(S) only: status code of the latest sample (cleared on failure
    /// so the badge never shows a stale "200" for a dead target).
    pub http_status: Option<u16>,
    /// HTTPS only: days until the peer certificate expires (sticky — the
    /// last known value survives probe failures; negative = expired).
    pub cert_days_left: Option<i64>,
    /// Sanitized reason for the latest failed sample (cleared on success).
    pub last_error: Option<String>,
    /// Machine-readable category for last_error.
    pub last_error_kind: Option<ProbeErrorKind>,
    /// True when the latest ICMP probe fell back to TCP because the OS
    /// refused native ICMP.
    pub tcp_fallback: bool,
    /// True when no fresh sample arrived within 2 × interval + timeout.
    pub stale: bool,
    /// Age of the latest sample in milliseconds (None before the first one).
    pub last_sample_age_ms: Option<u64>,
    /// Age at which this target is considered stale.
    pub stale_after_ms: u64,
}

pub struct TargetMetricTracker {
    pub id: u32,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub protocol: String,
    sent_count: u64,
    received_count: u64,
    lost_count: u64,
    last_rtt_ms: f64,
    min_rtt_ms: f64,
    max_rtt_ms: f64,
    sum_rtt_ms: f64,
    jitter_ms: f64,
    prev_rtt_ms: Option<f64>,
    recent_rtts: VecDeque<f64>,
    consecutive_failures: u32,
    consecutive_successes: u32,
    // Sticky "was offline" memory for hysteresis. A plain prev_status does
    // NOT work: the first recovering snapshot overwrites it with Degraded
    // and the second success already forgets the outage. Cleared on Online.
    was_offline: bool,
    last_http_status: Option<u16>,
    cert_days_left: Option<i64>,
    interval_ms: u64,
    timeout_ms: u64,
    last_checked_epoch_ms: u64,
    last_error: Option<String>,
    last_error_kind: Option<ProbeErrorKind>,
    tcp_fallback: bool,
}

impl TargetMetricTracker {
    pub fn new(id: u32, name: String, host: String, port: u16, protocol: String) -> Self {
        Self {
            id,
            name,
            host,
            port,
            protocol,
            sent_count: 0,
            received_count: 0,
            lost_count: 0,
            last_rtt_ms: 0.0,
            min_rtt_ms: f64::MAX,
            max_rtt_ms: 0.0,
            sum_rtt_ms: 0.0,
            jitter_ms: 0.0,
            prev_rtt_ms: None,
            recent_rtts: VecDeque::with_capacity(MAX_HISTORY_SAMPLES),
            consecutive_failures: 0,
            consecutive_successes: 0,
            was_offline: false,
            last_http_status: None,
            cert_days_left: None,
            interval_ms: 1_000,
            timeout_ms: 1_500,
            last_checked_epoch_ms: 0,
            last_error: None,
            last_error_kind: None,
            tcp_fallback: false,
        }
    }

    /// Same as Self::new, but with the target's real schedule so staleness
    /// is evaluated against 2 × interval + timeout.
    pub fn with_schedule(mut self, interval_ms: u64, timeout_ms: u64) -> Self {
        self.interval_ms = interval_ms.max(1);
        self.timeout_ms = timeout_ms.max(1);
        self
    }

    /// Backwards-compatible convenience wrapper used by tests and callers
    /// that only have a boolean outcome. Engine call sites use
    /// record_probe so the failure reason and ICMP fallback are preserved.
    pub fn record_sample(
        &mut self,
        success: bool,
        rtt_ms: f64,
        http_status: Option<u16>,
        cert_days_left: Option<i64>,
    ) {
        self.record_probe(ProbeSample {
            success,
            rtt_ms,
            http_status,
            cert_days_left,
            error_kind: None,
            error: None,
            tcp_fallback: false,
        });
    }

    pub fn record_probe(&mut self, sample: ProbeSample) {
        self.record_probe_at(sample, now_epoch_ms());
    }

    pub(crate) fn record_probe_at(&mut self, sample: ProbeSample, sampled_at_ms: u64) {
        let ProbeSample {
            success,
            rtt_ms,
            http_status,
            cert_days_left,
            error_kind,
            error,
            tcp_fallback,
        } = sample;

        self.sent_count += 1;
        // This is the sample's own completion timestamp. snapshot() must
        // never refresh it, otherwise a stalled probe would look fresh to
        // every scrape.
        self.last_checked_epoch_ms = sampled_at_ms;
        self.tcp_fallback = tcp_fallback;

        // Status is per-sample (a failed probe clears it); cert expiry is
        // sticky — the certificate does not vanish when a probe misses.
        self.last_http_status = http_status;
        if cert_days_left.is_some() {
            self.cert_days_left = cert_days_left;
        }

        if success {
            self.last_error = None;
            self.last_error_kind = None;
        } else {
            self.last_error_kind = Some(error_kind.unwrap_or(ProbeErrorKind::Other));
            self.last_error = Some(sanitize_error(error.as_deref().unwrap_or("probe failed")));
        }

        if success {
            self.received_count += 1;
            self.consecutive_failures = 0;
            self.consecutive_successes += 1;
            self.last_rtt_ms = rtt_ms;

            if rtt_ms < self.min_rtt_ms {
                self.min_rtt_ms = rtt_ms;
            }
            if rtt_ms > self.max_rtt_ms {
                self.max_rtt_ms = rtt_ms;
            }
            self.sum_rtt_ms += rtt_ms;

            // RFC 3550 Jitter algorithm: J = J + (|D| - J) / 16
            if let Some(prev) = self.prev_rtt_ms {
                let diff = (rtt_ms - prev).abs();
                self.jitter_ms += (diff - self.jitter_ms) / 16.0;
            }
            self.prev_rtt_ms = Some(rtt_ms);

            if self.recent_rtts.len() >= MAX_HISTORY_SAMPLES {
                self.recent_rtts.pop_front();
            }
            self.recent_rtts.push_back(rtt_ms);
        } else {
            self.lost_count += 1;
            self.consecutive_failures += 1;
            self.consecutive_successes = 0;
            self.last_rtt_ms = -1.0;

            if self.recent_rtts.len() >= MAX_HISTORY_SAMPLES {
                self.recent_rtts.pop_front();
            }
            self.recent_rtts.push_back(-1.0);
        }
    }

    pub fn snapshot(&mut self) -> TargetStats {
        let loss_rate = if self.sent_count > 0 {
            (self.lost_count as f64 / self.sent_count as f64) * 100.0
        } else {
            0.0
        };

        let avg_rtt_ms = if self.received_count > 0 {
            self.sum_rtt_ms / self.received_count as f64
        } else {
            0.0
        };

        let min_rtt = if self.min_rtt_ms == f64::MAX {
            0.0
        } else {
            self.min_rtt_ms
        };

        // Windowed loss over the recent ring buffer (<= 40 samples). The
        // lifetime `loss_rate` above is kept for totals, but status must
        // react to the present: with lifetime accounting a host that was
        // down for 10 minutes stays Degraded/Offline long after recovery.
        let (windowed_loss_rate, window_samples) = if self.recent_rtts.is_empty() {
            (0.0, 0)
        } else {
            let lost = self.recent_rtts.iter().filter(|v| **v < 0.0).count();
            (
                lost as f64 / self.recent_rtts.len() as f64 * 100.0,
                self.recent_rtts.len(),
            )
        };

        // Hysteresis: trip offline after `offline_after` consecutive
        // failures, but require `recover_after` consecutive successes to
        // leave it — one stray reply mid-outage must not flap Online and
        // spam a recovery alert. While confirming, the target reads
        // Degraded ("recovering") rather than Offline.
        let offline_after = OFFLINE_AFTER.load(Ordering::SeqCst).max(1);
        let recover_after = RECOVER_AFTER.load(Ordering::SeqCst).max(1);

        // Branch order matters: the recovering check comes BEFORE the
        // windowed-loss rule, otherwise a host climbing out of a long
        // outage could never reach it (its window stays >50% lost for up
        // to 40 samples) and hysteresis would be dead code.
        let status = if self.sent_count == 0 {
            TargetStatus::Pending
        } else if self.consecutive_failures >= offline_after {
            self.was_offline = true;
            TargetStatus::Offline
        } else if self.was_offline && self.consecutive_successes < recover_after {
            TargetStatus::Degraded
        } else if windowed_loss_rate > 50.0 {
            self.was_offline = true;
            TargetStatus::Offline
        } else if window_samples > 0
            && (windowed_loss_rate > 5.0 || self.last_rtt_ms > 180.0 || self.jitter_ms > 30.0)
        {
            TargetStatus::Degraded
        } else {
            self.was_offline = false;
            TargetStatus::Online
        };

        // Read the timestamp written by record_probe; do not stamp it here.
        // Staleness is the one value that legitimately depends on "now":
        // the sample time itself must stay fixed across every scrape.
        let stale_after_ms = self
            .interval_ms
            .saturating_mul(2)
            .saturating_add(self.timeout_ms);
        let last_sample_age_ms = if self.last_checked_epoch_ms == 0 {
            None
        } else {
            Some(now_epoch_ms().saturating_sub(self.last_checked_epoch_ms))
        };
        let stale = last_sample_age_ms.is_some_and(|age| age > stale_after_ms);

        TargetStats {
            id: self.id,
            name: self.name.clone(),
            host: self.host.clone(),
            port: self.port,
            protocol: self.protocol.clone(),
            status,
            sent_count: self.sent_count,
            received_count: self.received_count,
            lost_count: self.lost_count,
            loss_rate,
            last_rtt_ms: self.last_rtt_ms,
            min_rtt_ms: min_rtt,
            max_rtt_ms: self.max_rtt_ms,
            avg_rtt_ms,
            jitter_ms: self.jitter_ms,
            history: self.recent_rtts.iter().copied().collect(),
            last_checked_epoch_ms: self.last_checked_epoch_ms,
            http_status: self.last_http_status,
            cert_days_left: self.cert_days_left,
            last_error: self.last_error.clone(),
            last_error_kind: self.last_error_kind,
            tcp_fallback: self.tcp_fallback,
            stale,
            last_sample_age_ms,
            stale_after_ms,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    fn tracker() -> TargetMetricTracker {
        TargetMetricTracker::new(
            1,
            "Example".to_string(),
            "example.com".to_string(),
            443,
            "HTTPS".to_string(),
        )
        .with_schedule(1_000, 500)
    }

    #[test]
    fn snapshot_reads_the_sample_timestamp_instead_of_refreshing_it() {
        let mut tracker = tracker();
        tracker.record_probe_at(ProbeSample::success(12.0, Some(200), None), 1_000);
        let first = tracker.snapshot();
        thread::sleep(Duration::from_millis(20));
        let second = tracker.snapshot();

        assert_eq!(first.last_checked_epoch_ms, 1_000);
        assert_eq!(second.last_checked_epoch_ms, 1_000);
        assert!(second.last_sample_age_ms.unwrap() >= 20);
        assert!(second.stale);
    }

    #[test]
    fn failures_keep_sanitized_reason_kind_and_fallback() {
        let mut tracker = tracker();
        tracker.record_probe(ProbeSample {
            success: false,
            rtt_ms: -1.0,
            http_status: None,
            cert_days_left: None,
            error_kind: Some(ProbeErrorKind::Dns),
            error: Some("DNS \n resolution\t failed ".to_string()),
            tcp_fallback: true,
        });
        let stats = tracker.snapshot();
        assert_eq!(stats.last_error.as_deref(), Some("DNS resolution failed"));
        assert_eq!(stats.last_error_kind, Some(ProbeErrorKind::Dns));
        assert!(stats.tcp_fallback);

        tracker.record_probe(ProbeSample::success(4.0, None, None));
        let recovered = tracker.snapshot();
        assert!(recovered.last_error.is_none());
        assert!(recovered.last_error_kind.is_none());
        assert!(!recovered.tcp_fallback);
    }

    #[test]
    fn sanitize_error_caps_length_and_rejects_control_characters() {
        let noisy = format!("first\nsecond\u{0}{}", "x".repeat(300));
        let clean = sanitize_error(&noisy);
        assert_eq!(clean.chars().count(), MAX_ERROR_CHARS);
        assert!(clean.starts_with("first second xxx"));
        assert!(clean.ends_with("..."));
        assert_eq!(sanitize_error("\n\t "), "probe failed");
    }
}

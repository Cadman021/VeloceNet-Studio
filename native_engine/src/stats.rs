use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU32, Ordering};

const MAX_HISTORY_SAMPLES: usize = 40;

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
        }
    }

    pub fn record_sample(
        &mut self,
        success: bool,
        rtt_ms: f64,
        http_status: Option<u16>,
        cert_days_left: Option<i64>,
    ) {
        self.sent_count += 1;

        // Status is per-sample (a failed probe clears it); cert expiry is
        // sticky — the certificate does not vanish when a probe misses.
        self.last_http_status = http_status;
        if cert_days_left.is_some() {
            self.cert_days_left = cert_days_left;
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

        let epoch_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);

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
            last_checked_epoch_ms: epoch_ms,
            http_status: self.last_http_status,
            cert_days_left: self.cert_days_left,
        }
    }
}

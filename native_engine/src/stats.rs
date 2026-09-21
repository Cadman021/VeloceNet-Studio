use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

const MAX_HISTORY_SAMPLES: usize = 40;

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
        }
    }

    pub fn record_sample(&mut self, success: bool, rtt_ms: f64) {
        self.sent_count += 1;

        if success {
            self.received_count += 1;
            self.consecutive_failures = 0;
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
            self.last_rtt_ms = -1.0;

            if self.recent_rtts.len() >= MAX_HISTORY_SAMPLES {
                self.recent_rtts.pop_front();
            }
            self.recent_rtts.push_back(-1.0);
        }
    }

    pub fn snapshot(&self) -> TargetStats {
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

        let min_rtt = if self.min_rtt_ms == f64::MAX { 0.0 } else { self.min_rtt_ms };

        let status = if self.sent_count == 0 {
            TargetStatus::Pending
        } else if self.consecutive_failures >= 3 || loss_rate > 50.0 {
            TargetStatus::Offline
        } else if loss_rate > 5.0 || self.last_rtt_ms > 180.0 || self.jitter_ms > 30.0 {
            TargetStatus::Degraded
        } else {
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
        }
    }
}

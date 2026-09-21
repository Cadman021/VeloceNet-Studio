pub mod bandwidth;
pub mod engine;
pub mod ffi;
pub mod probe;
pub mod stats;
pub mod traceroute;
pub mod warp;

pub use bandwidth::{BandwidthMonitor, BandwidthSnapshot, InterfaceStat, ProcessTraffic};
pub use engine::{Engine, TargetConfig};
pub use ffi::*;
pub use stats::{TargetMetricTracker, TargetStats, TargetStatus};
pub use traceroute::{HopInfo, TracerouteManager, TracerouteProgress};
pub use warp::{WarpManager, WarpProgress, WarpResult};

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn test_tcp_probe_dns_or_connection() {
        // Probe Google DNS on port 53 via TCP
        let result = probe::tcp::probe_tcp("8.8.8.8", 53, Duration::from_millis(2000)).await;
        // In local or isolated network this might be blocked or succeed; either way it shouldn't panic
        println!("TCP probe result: {:?}", result);
    }

    #[test]
    fn test_stats_tracker_math() {
        let mut tracker = TargetMetricTracker::new(
            1,
            "Cloudflare".to_string(),
            "1.1.1.1".to_string(),
            53,
            "TCP".to_string(),
        );

        tracker.record_sample(true, 20.0);
        tracker.record_sample(true, 30.0);
        tracker.record_sample(false, -1.0);

        let snap = tracker.snapshot();
        assert_eq!(snap.sent_count, 3);
        assert_eq!(snap.received_count, 2);
        assert_eq!(snap.lost_count, 1);
        assert!((snap.loss_rate - 33.333).abs() < 1.0);
        assert_eq!(snap.min_rtt_ms, 20.0);
        assert_eq!(snap.max_rtt_ms, 30.0);
        assert_eq!(snap.avg_rtt_ms, 25.0);
    }
}

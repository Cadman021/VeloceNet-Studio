pub mod bandwidth;
pub mod engine;
pub mod ffi;
pub mod probe;
pub mod stats;
pub mod traceroute;
pub mod warp;
mod wireguard;

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
    async fn test_tcp_probe_open_port_succeeds() {
        // Local listener: deterministic, no internet needed (the old test
        // hit 8.8.8.8 with no asserts — useless and flaky offline).
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let port = listener.local_addr().expect("addr").port();
        let handle = tokio::task::spawn_blocking(move || {
            let _ = listener.accept();
        });
        let result = probe::tcp::probe_tcp("127.0.0.1", port, Duration::from_millis(2000)).await;
        let _ = handle.await;
        assert!(result.success, "open local port must succeed");
        assert!(result.rtt_ms >= 0.0);
        assert!(result.error.is_none());
    }

    #[tokio::test]
    async fn test_tcp_probe_closed_port_fails() {
        // Grab an ephemeral port, drop the listener, then probe the now
        // closed port: connection must be refused (fast, deterministic).
        let port = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind loopback");
            listener.local_addr().expect("addr").port()
        };
        let result = probe::tcp::probe_tcp("127.0.0.1", port, Duration::from_millis(2000)).await;
        assert!(!result.success, "closed local port must fail");
        assert_eq!(result.rtt_ms, -1.0);
        assert!(result.error.is_some());
    }

    #[tokio::test]
    async fn test_tcp_probe_unresolvable_host_fails() {
        let result =
            probe::tcp::probe_tcp("nonexistent.invalid", 80, Duration::from_millis(1500)).await;
        assert!(!result.success);
        assert!(result.error.is_some());
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

        tracker.record_sample(true, 20.0, None, None);
        tracker.record_sample(true, 30.0, None, None);
        tracker.record_sample(false, -1.0, None, None);

        let snap = tracker.snapshot();
        assert_eq!(snap.sent_count, 3);
        assert_eq!(snap.received_count, 2);
        assert_eq!(snap.lost_count, 1);
        assert!((snap.loss_rate - 33.333).abs() < 1.0);
        assert_eq!(snap.min_rtt_ms, 20.0);
        assert_eq!(snap.max_rtt_ms, 30.0);
        assert_eq!(snap.avg_rtt_ms, 25.0);
    }

    // NOTE: threshold tests live in ONE #[test] fn on purpose. The
    // thresholds are process-global statics and Rust runs tests in parallel
    // threads — separate fns would flake each other (and the older tests
    // that assume defaults). The pre-existing tests stay green under any
    // threshold ≤ 20, and defaults are restored at the end regardless.
    #[test]
    fn test_alert_thresholds_and_hysteresis() {
        fn make_tracker() -> TargetMetricTracker {
            TargetMetricTracker::new(
                9,
                "Hyst".to_string(),
                "10.9.9.9".to_string(),
                80,
                "TCP".to_string(),
            )
        }

        // --- Configurable trip point: 10 healthy then 4-5 failures. ---
        crate::stats::set_alert_thresholds(5, 2);
        let mut tracker = make_tracker();
        for _ in 0..10 {
            tracker.record_sample(true, 20.0, None, None);
        }
        for _ in 0..4 {
            tracker.record_sample(false, -1.0, None, None);
        }
        // 4 consecutive < 5 and windowed loss 4/14 < 50%: degraded, offline.
        assert_eq!(tracker.snapshot().status, TargetStatus::Degraded);
        tracker.record_sample(false, -1.0, None, None);
        assert_eq!(tracker.snapshot().status, TargetStatus::Offline);

        // --- Hysteresis: recovery needs consecutive successes. ---
        crate::stats::set_alert_thresholds(3, 3);
        let mut tracker = make_tracker();
        for _ in 0..3 {
            tracker.record_sample(false, -1.0, None, None);
        }
        assert_eq!(tracker.snapshot().status, TargetStatus::Offline);
        // Stray successes must NOT flip straight to Online.
        tracker.record_sample(true, 20.0, None, None);
        assert_eq!(tracker.snapshot().status, TargetStatus::Degraded);
        tracker.record_sample(true, 20.0, None, None);
        assert_eq!(tracker.snapshot().status, TargetStatus::Degraded);
        // Flood with health: the 40-sample window goes fully clean and the
        // consecutive count clears the bar → Online.
        for _ in 0..60 {
            tracker.record_sample(true, 20.0, None, None);
        }
        assert_eq!(tracker.snapshot().status, TargetStatus::Online);

        crate::stats::set_alert_thresholds(3, 2);
    }

    #[test]
    fn test_http_meta_is_per_sample_and_cert_days_stick() {
        let mut tracker = TargetMetricTracker::new(
            3,
            "Web".to_string(),
            "example.com".to_string(),
            443,
            "HTTPS".to_string(),
        );

        tracker.record_sample(true, 120.0, Some(200), Some(30));
        let snap = tracker.snapshot();
        assert_eq!(snap.http_status, Some(200));
        assert_eq!(snap.cert_days_left, Some(30));

        // A failed probe clears the status (no stale "200" badge) but the
        // last known certificate expiry survives.
        tracker.record_sample(false, -1.0, None, None);
        let snap = tracker.snapshot();
        assert_eq!(snap.http_status, None);
        assert_eq!(snap.cert_days_left, Some(30));

        // A fresh TLS handshake updates the cert days.
        tracker.record_sample(true, 110.0, Some(204), Some(29));
        let snap = tracker.snapshot();
        assert_eq!(snap.http_status, Some(204));
        assert_eq!(snap.cert_days_left, Some(29));
    }

    #[test]
    fn test_status_recovers_on_recent_window() {
        // Down for a long while (40 losses fill the window → Offline),
        // then healthy again: status must follow the recent window back
        // to Online/ Degraded instead of sticking on lifetime loss.
        let mut tracker = TargetMetricTracker::new(
            2,
            "Flaky".to_string(),
            "10.0.0.1".to_string(),
            80,
            "TCP".to_string(),
        );

        for _ in 0..40 {
            tracker.record_sample(false, -1.0, None, None);
        }
        assert_eq!(tracker.snapshot().status, TargetStatus::Offline);

        // 40 healthy samples push every loss out of the 40-sample window.
        for _ in 0..40 {
            tracker.record_sample(true, 20.0, None, None);
        }
        let snap = tracker.snapshot();
        // Lifetime loss is still 50%, but the window is clean.
        assert!((snap.loss_rate - 50.0).abs() < 1.0);
        assert_eq!(snap.status, TargetStatus::Online);
    }
}

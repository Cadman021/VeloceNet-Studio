use std::net::SocketAddr;
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::time::timeout;

use crate::stats::ProbeErrorKind;

#[derive(Debug, Clone)]
pub struct ProbeResult {
    pub success: bool,
    pub rtt_ms: f64,
    pub error: Option<String>,
    /// True only when ICMP could not even be attempted because the OS
    /// refused ping sockets — a genuinely failed probe must NOT trigger
    /// the TCP fallback (that would mix TCP RTTs into ICMP stats).
    pub icmp_unavailable: bool,
    /// HTTP probes only: status code of the response, when one arrived.
    pub http_status: Option<u16>,
    /// HTTPS probes only: days until the peer certificate expires
    /// (negative = already expired). Sticky in the tracker.
    pub cert_days_left: Option<i64>,
    /// Machine-readable reason for a failed probe.
    pub error_kind: Option<ProbeErrorKind>,
    /// True when an ICMP probe fell back to TCP because native ICMP was
    /// unavailable. The sample's RTT/error then belongs to the TCP attempt.
    pub tcp_fallback: bool,
}

impl ProbeResult {
    pub fn success(rtt_ms: f64) -> Self {
        Self {
            success: true,
            rtt_ms,
            error: None,
            icmp_unavailable: false,
            http_status: None,
            cert_days_left: None,
            error_kind: None,
            tcp_fallback: false,
        }
    }

    pub fn failure(error: impl Into<String>) -> Self {
        Self::failure_kind(ProbeErrorKind::Other, error)
    }

    pub fn failure_kind(kind: ProbeErrorKind, error: impl Into<String>) -> Self {
        Self {
            success: false,
            rtt_ms: -1.0,
            error: Some(error.into()),
            icmp_unavailable: false,
            http_status: None,
            cert_days_left: None,
            error_kind: Some(kind),
            tcp_fallback: false,
        }
    }

    pub fn icmp_unavailable(error: impl Into<String>) -> Self {
        Self {
            success: false,
            rtt_ms: -1.0,
            error: Some(error.into()),
            icmp_unavailable: true,
            http_status: None,
            cert_days_left: None,
            error_kind: Some(ProbeErrorKind::IcmpUnavailable),
            tcp_fallback: false,
        }
    }

    /// Marks a result as the TCP fallback for an ICMP probe.
    pub fn with_tcp_fallback(mut self) -> Self {
        self.tcp_fallback = true;
        self
    }

    pub fn with_error_kind(mut self, kind: ProbeErrorKind) -> Self {
        self.error_kind = Some(kind);
        self
    }

    /// HTTP(S) result: success is the caller's verdict on `status`.
    pub fn http(
        success: bool,
        rtt_ms: f64,
        status: Option<u16>,
        cert_days_left: Option<i64>,
        error: Option<String>,
    ) -> Self {
        let error_kind = error.as_ref().map(|_| ProbeErrorKind::Http);
        Self {
            success,
            rtt_ms,
            error,
            icmp_unavailable: false,
            http_status: status,
            cert_days_left,
            error_kind,
            tcp_fallback: false,
        }
    }
}

/// Classifies a connect/read error without relying on a platform-specific
/// numeric code. The message fallback catches Windows/Winsock wording that
/// does not map to the portable ErrorKind variants.
pub fn classify_io_error(error: &std::io::Error) -> ProbeErrorKind {
    match error.kind() {
        std::io::ErrorKind::ConnectionRefused => ProbeErrorKind::Refused,
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => ProbeErrorKind::Timeout,
        _ => {
            let text = error.to_string().to_ascii_lowercase();
            if text.contains("refused") {
                ProbeErrorKind::Refused
            } else if text.contains("timed out") {
                ProbeErrorKind::Timeout
            } else if text.contains("unreachable") {
                ProbeErrorKind::Unreachable
            } else if text.contains("name") || text.contains("dns") || text.contains("resolve") {
                ProbeErrorKind::Dns
            } else {
                ProbeErrorKind::Other
            }
        }
    }
}

/// Resolves a host once; the engine loop caches the result instead of
/// paying DNS on every tick.
pub async fn resolve_target_addrs(
    host: &str,
    port: u16,
    timeout_duration: Duration,
) -> Result<Vec<SocketAddr>, ProbeResult> {
    let addr_str = format!("{}:{}", host, port);
    let resolve_result = timeout(timeout_duration, tokio::net::lookup_host(&addr_str)).await;

    match resolve_result {
        Ok(Ok(iter)) => {
            let addrs: Vec<SocketAddr> = iter.collect();
            if addrs.is_empty() {
                return Err(ProbeResult::failure_kind(
                    ProbeErrorKind::Dns,
                    "No IP address resolved for host",
                ));
            }
            Ok(addrs)
        }
        Ok(Err(e)) => Err(ProbeResult::failure_kind(
            ProbeErrorKind::Dns,
            format!("DNS resolution failed: {}", e),
        )),
        Err(_) => Err(ProbeResult::failure_kind(
            ProbeErrorKind::Timeout,
            "DNS resolution timed out",
        )),
    }
}

/// Tries resolved addresses in order within one overall budget (sequential
/// happy-eyeballs-lite: a dead first address, e.g. broken IPv6, no longer
/// condemns the target while a working sibling exists).
pub async fn probe_tcp_addrs(addrs: &[SocketAddr], timeout_duration: Duration) -> ProbeResult {
    let deadline = Instant::now() + timeout_duration;
    let mut last_error = "Connection timed out".to_string();
    let mut last_kind = ProbeErrorKind::Timeout;

    for addr in addrs {
        let remaining = match deadline.checked_duration_since(Instant::now()) {
            Some(rem) if rem > Duration::from_millis(5) => rem,
            _ => break,
        };
        let connect_start = Instant::now();
        match timeout(remaining, TcpStream::connect(*addr)).await {
            Ok(Ok(stream)) => {
                let rtt = connect_start.elapsed().as_secs_f64() * 1000.0;
                drop(stream);
                return ProbeResult::success(rtt);
            }
            Ok(Err(e)) => {
                last_kind = classify_io_error(&e);
                last_error = format!("Connect failed: {}", e);
            }
            Err(_) => {
                last_kind = ProbeErrorKind::Timeout;
                last_error = "Connection timed out".to_string();
            }
        }
    }

    ProbeResult::failure_kind(last_kind, last_error)
}

pub async fn probe_tcp(host: &str, port: u16, timeout_duration: Duration) -> ProbeResult {
    let start = Instant::now();
    let addrs = match resolve_target_addrs(host, port, timeout_duration).await {
        Ok(addrs) => addrs,
        Err(failure) => return failure,
    };
    let remaining = match timeout_duration.checked_sub(start.elapsed()) {
        Some(rem) if rem > Duration::from_millis(5) => rem,
        _ => {
            return ProbeResult::failure_kind(ProbeErrorKind::Timeout, "Timeout during resolution")
        }
    };
    probe_tcp_addrs(&addrs, remaining).await
}

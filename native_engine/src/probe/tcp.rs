use std::net::SocketAddr;
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::time::timeout;

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
        }
    }

    pub fn failure(error: impl Into<String>) -> Self {
        Self {
            success: false,
            rtt_ms: -1.0,
            error: Some(error.into()),
            icmp_unavailable: false,
            http_status: None,
            cert_days_left: None,
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
        }
    }

    /// HTTP(S) result: success is the caller's verdict on `status`.
    pub fn http(
        success: bool,
        rtt_ms: f64,
        status: Option<u16>,
        cert_days_left: Option<i64>,
        error: Option<String>,
    ) -> Self {
        Self {
            success,
            rtt_ms,
            error,
            icmp_unavailable: false,
            http_status: status,
            cert_days_left,
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
                return Err(ProbeResult::failure("No IP address resolved for host"));
            }
            Ok(addrs)
        }
        Ok(Err(e)) => Err(ProbeResult::failure(format!(
            "DNS resolution failed: {}",
            e
        ))),
        Err(_) => Err(ProbeResult::failure("DNS resolution timed out")),
    }
}

/// Tries resolved addresses in order within one overall budget (sequential
/// happy-eyeballs-lite: a dead first address, e.g. broken IPv6, no longer
/// condemns the target while a working sibling exists).
pub async fn probe_tcp_addrs(addrs: &[SocketAddr], timeout_duration: Duration) -> ProbeResult {
    let deadline = Instant::now() + timeout_duration;
    let mut last_error = "No IP address resolved for host".to_string();

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
                last_error = format!("Connect failed: {}", e);
            }
            Err(_) => {
                last_error = "Connection timed out".to_string();
            }
        }
    }

    ProbeResult::failure(last_error)
}

pub async fn probe_tcp(host: &str, port: u16, timeout_duration: Duration) -> ProbeResult {
    let start = Instant::now();
    let addrs = match resolve_target_addrs(host, port, timeout_duration).await {
        Ok(addrs) => addrs,
        Err(failure) => return failure,
    };
    let remaining = match timeout_duration.checked_sub(start.elapsed()) {
        Some(rem) if rem > Duration::from_millis(5) => rem,
        _ => return ProbeResult::failure("Timeout during resolution"),
    };
    probe_tcp_addrs(&addrs, remaining).await
}

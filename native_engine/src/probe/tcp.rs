use std::net::SocketAddr;
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio::time::timeout;

#[derive(Debug, Clone)]
pub struct ProbeResult {
    pub success: bool,
    pub rtt_ms: f64,
    pub error: Option<String>,
}

pub async fn probe_tcp(host: &str, port: u16, timeout_duration: Duration) -> ProbeResult {
    let start = Instant::now();
    let addr_str = format!("{}:{}", host, port);

    let resolve_result = timeout(timeout_duration, tokio::net::lookup_host(&addr_str)).await;

    let addrs: Vec<SocketAddr> = match resolve_result {
        Ok(Ok(iter)) => iter.collect(),
        Ok(Err(e)) => {
            return ProbeResult {
                success: false,
                rtt_ms: -1.0,
                error: Some(format!("DNS resolution failed: {}", e)),
            }
        }
        Err(_) => {
            return ProbeResult {
                success: false,
                rtt_ms: -1.0,
                error: Some("DNS resolution timed out".to_string()),
            }
        }
    };

    if addrs.is_empty() {
        return ProbeResult {
            success: false,
            rtt_ms: -1.0,
            error: Some("No IP address resolved for host".to_string()),
        };
    }

    // Connect to the first resolved address
    let target_addr = addrs[0];
    let remaining_timeout = match timeout_duration.checked_sub(start.elapsed()) {
        Some(rem) if rem > Duration::from_millis(5) => rem,
        _ => {
            return ProbeResult {
                success: false,
                rtt_ms: -1.0,
                error: Some("Timeout during resolution".to_string()),
            }
        }
    };

    let connect_start = Instant::now();
    match timeout(remaining_timeout, TcpStream::connect(target_addr)).await {
        Ok(Ok(stream)) => {
            let rtt = connect_start.elapsed().as_secs_f64() * 1000.0;
            drop(stream);
            ProbeResult {
                success: true,
                rtt_ms: rtt,
                error: None,
            }
        }
        Ok(Err(e)) => ProbeResult {
            success: false,
            rtt_ms: -1.0,
            error: Some(format!("Connect failed: {}", e)),
        },
        Err(_) => ProbeResult {
            success: false,
            rtt_ms: -1.0,
            error: Some("Connection timed out".to_string()),
        },
    }
}

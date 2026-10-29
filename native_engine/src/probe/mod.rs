pub mod http;
pub mod tcp;
#[cfg(unix)]
pub mod unix_icmp;
#[cfg(windows)]
pub mod windows_icmp;

use std::time::Duration;
use tcp::{probe_tcp, ProbeResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeProtocol {
    Icmp = 0,
    Tcp = 1,
    Http = 2,
    Https = 3,
}

impl ProbeProtocol {
    pub fn from_u32(val: u32) -> Self {
        match val {
            1 => ProbeProtocol::Tcp,
            2 => ProbeProtocol::Http,
            3 => ProbeProtocol::Https,
            _ => ProbeProtocol::Icmp,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            ProbeProtocol::Icmp => "ICMP",
            ProbeProtocol::Tcp => "TCP",
            ProbeProtocol::Http => "HTTP",
            ProbeProtocol::Https => "HTTPS",
        }
    }
}

/// `path` is only consumed by the HTTP(S) protocols (defaults to "/" there).
pub async fn execute_probe(
    protocol: ProbeProtocol,
    host: &str,
    port: u16,
    path: &str,
    timeout_duration: Duration,
) -> ProbeResult {
    match protocol {
        ProbeProtocol::Icmp => {
            let host_owned = host.to_string();
            let timeout_ms = timeout_duration.as_millis().min(u32::MAX as u128) as u32;

            // Both ICMP implementations are blocking (Iphlpapi / ping
            // sockets), so they run on the blocking thread pool and never
            // stall the async executor.
            let probe_result = {
                #[cfg(windows)]
                {
                    match tokio::task::spawn_blocking(move || {
                        windows_icmp::imp::ping_icmp_sync(&host_owned, timeout_ms)
                    })
                    .await
                    {
                        Ok(r) => r,
                        Err(e) => ProbeResult::failure(format!("Task execution failed: {}", e)),
                    }
                }
                #[cfg(unix)]
                {
                    match tokio::task::spawn_blocking(move || {
                        unix_icmp::ping_icmp_sync(&host_owned, timeout_ms)
                    })
                    .await
                    {
                        Ok(r) => r,
                        Err(e) => ProbeResult::failure(format!("Task execution failed: {}", e)),
                    }
                }
                #[cfg(not(any(windows, unix)))]
                {
                    let _ = (&host_owned, timeout_ms);
                    ProbeResult::icmp_unavailable("ICMP is not supported on this platform")
                }
            };

            // NOTE: the TCP fallback now fires only where the OS refused
            // native ICMP entirely (no ping sockets, no privileges) — NOT
            // on a genuine probe failure. Mixing TCP RTTs into ICMP stats
            // corrupts loss/RTT accounting and doubles the effective
            // timeout, which is why Windows already had no silent fallback.
            if probe_result.icmp_unavailable && port > 0 {
                return probe_tcp(host, port, timeout_duration).await;
            }
            probe_result
        }
        ProbeProtocol::Tcp => {
            let p = if port == 0 { 80 } else { port };
            probe_tcp(host, p, timeout_duration).await
        }
        ProbeProtocol::Http | ProbeProtocol::Https => {
            let tls = protocol == ProbeProtocol::Https;
            let host_owned = host.to_string();
            let path_owned = path.to_string();
            let timeout_ms = timeout_duration.as_millis().min(u32::MAX as u128) as u32;
            let p = default_http_port(port, tls);

            // Blocking (std TcpStream + sync rustls): spawn_blocking keeps
            // the TLS handshake and socket waits off the async workers.
            match tokio::task::spawn_blocking(move || {
                http::probe_http_sync(&host_owned, p, tls, &path_owned, timeout_ms)
            })
            .await
            {
                Ok(r) => r,
                Err(e) => ProbeResult::failure(format!("Task execution failed: {}", e)),
            }
        }
    }
}

fn default_http_port(port: u16, tls: bool) -> u16 {
    if port != 0 {
        port
    } else if tls {
        443
    } else {
        80
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::probe::tcp::ProbeResult;

    /// The `icmp_unavailable` flag is the ONLY thing that licenses the TCP
    /// fallback: a genuine ICMP failure (timeout, TTL expired, unreachable)
    /// must keep its ICMP verdict or the matrix would silently mix TCP RTTs
    /// into ICMP loss/RTT accounting. This pins that contract on every
    /// platform so the classification can't drift unnoticed.
    #[test]
    fn icmp_unavailable_is_the_only_fallback_trigger() {
        let genuine = ProbeResult::failure("ICMP request timed out");
        assert!(!genuine.icmp_unavailable);

        let refused = ProbeResult::icmp_unavailable("ICMP datagram sockets unavailable");
        assert!(refused.icmp_unavailable);
        assert!(!refused.success);

        let ok = ProbeResult::success(1.5);
        assert!(!ok.icmp_unavailable);
        assert!(ok.success);
    }

    #[test]
    fn http_protocol_ids_map_both_directions() {
        assert_eq!(ProbeProtocol::from_u32(2), ProbeProtocol::Http);
        assert_eq!(ProbeProtocol::from_u32(3), ProbeProtocol::Https);
        assert_eq!(ProbeProtocol::from_u32(0), ProbeProtocol::Icmp);
        assert_eq!(ProbeProtocol::from_u32(1), ProbeProtocol::Tcp);
        // Unknown ids degrade to ICMP (the historical default), never panic.
        assert_eq!(ProbeProtocol::from_u32(99), ProbeProtocol::Icmp);
        assert_eq!(ProbeProtocol::Http.as_str(), "HTTP");
        assert_eq!(ProbeProtocol::Https.as_str(), "HTTPS");
    }

    #[test]
    fn default_http_port_respects_explicit_and_scheme_defaults() {
        assert_eq!(default_http_port(0, false), 80);
        assert_eq!(default_http_port(0, true), 443);
        // An explicit port always wins, even on the "wrong" scheme.
        assert_eq!(default_http_port(8080, false), 8080);
        assert_eq!(default_http_port(8443, true), 8443);
    }
}

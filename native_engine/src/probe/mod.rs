pub mod tcp;
pub mod windows_icmp;

use std::time::Duration;
use tcp::{probe_tcp, ProbeResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeProtocol {
    Icmp = 0,
    Tcp = 1,
}

impl ProbeProtocol {
    pub fn from_u32(val: u32) -> Self {
        match val {
            1 => ProbeProtocol::Tcp,
            _ => ProbeProtocol::Icmp,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            ProbeProtocol::Icmp => "ICMP",
            ProbeProtocol::Tcp => "TCP",
        }
    }
}

pub async fn execute_probe(
    protocol: ProbeProtocol,
    host: &str,
    port: u16,
    timeout_duration: Duration,
) -> ProbeResult {
    match protocol {
        ProbeProtocol::Icmp => {
            let host_owned = host.to_string();
            let timeout_ms = timeout_duration.as_millis().min(u32::MAX as u128) as u32;

            // Run Windows ICMP in blocking thread pool so it does not block the async executor
            let res = tokio::task::spawn_blocking(move || {
                windows_icmp::imp::ping_icmp_sync(&host_owned, timeout_ms)
            })
            .await;

            match res {
                Ok(probe_result) => {
                    // If ICMP failed due to platform or raw socket, fallback to TCP on port if port > 0
                    if !probe_result.success && port > 0 {
                        probe_tcp(host, port, timeout_duration).await
                    } else {
                        probe_result
                    }
                }
                Err(e) => ProbeResult {
                    success: false,
                    rtt_ms: -1.0,
                    error: Some(format!("Task execution failed: {}", e)),
                },
            }
        }
        ProbeProtocol::Tcp => {
            let p = if port == 0 { 80 } else { port };
            probe_tcp(host, p, timeout_duration).await
        }
    }
}

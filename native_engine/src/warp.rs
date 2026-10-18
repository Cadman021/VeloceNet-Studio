use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// One tested Warp endpoint (ip + port + measured RTT).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WarpResult {
    pub ip: String,
    pub port: u16,
    pub endpoint: String,
    pub rtt_ms: f64,
    pub success: bool,
    pub error: Option<String>,
}

/// Live progress of a running Warp scan session.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WarpProgress {
    pub session_id: u32,
    pub total: usize,
    pub tested: usize,
    pub succeeded: usize,
    pub failed: usize,
    pub is_running: bool,
    pub is_completed: bool,
    pub error: Option<String>,
    pub results: Vec<WarpResult>,
}

/// Incremental poll payload: counters plus only the results appended since
/// `from_index`. A full 4096-result snapshot serialized every 500ms poll is
/// ~1MB of JSON churn per tick; deltas keep steady-state polls tiny.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WarpDelta {
    pub session_id: u32,
    pub total: usize,
    pub tested: usize,
    pub succeeded: usize,
    pub failed: usize,
    pub is_running: bool,
    pub is_completed: bool,
    pub error: Option<String>,
    pub from_index: usize,
    pub new_results: Vec<WarpResult>,
}

/// Shared work queue: `(original index, (ip, port))` pairs for warp workers.
type JobQueue = Arc<RwLock<Vec<(usize, (String, u16))>>>;

pub struct WarpManager {
    sessions: Arc<RwLock<HashMap<u32, Arc<RwLock<WarpProgress>>>>>,
    cancel_flags: Arc<RwLock<HashMap<u32, Arc<AtomicBool>>>>,
    next_session_id: AtomicU32,
}

/// Max concurrent scans: each spawns a coordinator thread plus up to 64
/// workers, and sessions only vanish on explicit free.
pub const MAX_WARP_SESSIONS: usize = 4;

impl Default for WarpManager {
    fn default() -> Self {
        Self::new()
    }
}

impl WarpManager {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            cancel_flags: Arc::new(RwLock::new(HashMap::new())),
            next_session_id: AtomicU32::new(1),
        }
    }

    /// Start a scan over the given endpoints (already expanded ip:port list).
    /// `parallel` = worker thread count (clamped 1..64), `timeout_ms` per probe.
    pub fn start_scan(&self, endpoints: Vec<(String, u16)>, parallel: u32, timeout_ms: u32) -> u32 {
        // Same prune-then-cap policy as TracerouteManager: finished
        // sessions are reclaimed from both maps, refusal is the last resort.
        let finished: Vec<u32> = self
            .sessions
            .read()
            .iter()
            .filter(|(_, p)| !p.read().is_running)
            .map(|(id, _)| *id)
            .collect();
        for id in finished {
            self.sessions.write().remove(&id);
            self.cancel_flags.write().remove(&id);
        }
        if self.sessions.read().len() >= MAX_WARP_SESSIONS {
            return 0;
        }
        let session_id = self.next_session_id.fetch_add(1, Ordering::SeqCst);
        let parallel = parallel.clamp(1, 64) as usize;
        let timeout_ms = (if timeout_ms == 0 {
            1200
        } else {
            timeout_ms.min(5000)
        }) as u64;

        let progress = Arc::new(RwLock::new(WarpProgress {
            session_id,
            total: endpoints.len(),
            tested: 0,
            succeeded: 0,
            failed: 0,
            is_running: true,
            is_completed: false,
            error: None,
            results: Vec::with_capacity(endpoints.len()),
        }));

        let cancel_flag = Arc::new(AtomicBool::new(false));
        self.sessions.write().insert(session_id, progress.clone());
        self.cancel_flags
            .write()
            .insert(session_id, cancel_flag.clone());

        std::thread::spawn(move || {
            run_scan_worker(endpoints, parallel, timeout_ms, progress, cancel_flag);
        });

        session_id
    }

    pub fn poll_progress_json(&self, session_id: u32) -> Option<String> {
        let sessions = self.sessions.read();
        sessions
            .get(&session_id)
            .and_then(|p| serde_json::to_string(&p.read().clone()).ok())
    }

    pub fn poll_delta_json(&self, session_id: u32, since: usize) -> Option<String> {
        let sessions = self.sessions.read();
        let prog = sessions.get(&session_id)?.read();
        let from = since.min(prog.results.len());
        let delta = WarpDelta {
            session_id: prog.session_id,
            total: prog.total,
            tested: prog.tested,
            succeeded: prog.succeeded,
            failed: prog.failed,
            is_running: prog.is_running,
            is_completed: prog.is_completed,
            error: prog.error.clone(),
            from_index: from,
            new_results: prog.results[from..].to_vec(),
        };
        serde_json::to_string(&delta).ok()
    }

    pub fn stop_scan(&self, session_id: u32) -> bool {
        let flags = self.cancel_flags.read();
        if let Some(flag) = flags.get(&session_id) {
            flag.store(true, Ordering::SeqCst);
            if let Some(p) = self.sessions.read().get(&session_id) {
                let mut prog = p.write();
                prog.is_running = false;
                prog.is_completed = true;
            }
            true
        } else {
            false
        }
    }

    pub fn free_session(&self, session_id: u32) {
        self.stop_scan(session_id);
        self.sessions.write().remove(&session_id);
        self.cancel_flags.write().remove(&session_id);
    }
}

fn run_scan_worker(
    endpoints: Vec<(String, u16)>,
    parallel: usize,
    timeout_ms: u64,
    progress: Arc<RwLock<WarpProgress>>,
    cancel_flag: Arc<AtomicBool>,
) {
    use std::sync::mpsc::channel;

    let (tx, rx) = channel::<(usize, WarpResult)>();
    let queue: JobQueue = Arc::new(RwLock::new(endpoints.into_iter().enumerate().collect()));

    let mut workers = Vec::with_capacity(parallel);
    for _ in 0..parallel {
        let queue = queue.clone();
        let tx = tx.clone();
        let cancel = cancel_flag.clone();
        workers.push(std::thread::spawn(move || loop {
            if cancel.load(Ordering::SeqCst) {
                break;
            }
            let job: Option<(usize, (String, u16))> = queue.write().pop();
            match job {
                Some((idx, (ip, port))) => {
                    let res = probe_warp_endpoint(&ip, port, timeout_ms);
                    let _ = tx.send((idx, res));
                }
                None => break,
            }
        }));
    }
    drop(tx);

    // Collect out-of-order, then keep results sorted by original index so
    // the UI list is stable; Dart sorts by RTT for ranking anyway.
    // NOTE: progress is published incrementally inside the loop (previously
    // it was written only here at the end, so polling UIs showed 0% until
    // the whole scan finished). Arrival order during the scan, index order
    // at completion — Dart re-sorts for ranking either way.
    let mut collected: Vec<(usize, WarpResult)> = Vec::new();
    for (idx, res) in rx {
        if cancel_flag.load(Ordering::SeqCst) {
            break;
        }
        let ok = res.success;
        collected.push((idx, res.clone()));
        {
            let mut p = progress.write();
            p.tested = collected.len();
            if ok {
                p.succeeded += 1;
            } else {
                p.failed += 1;
            }
            p.results.push(res);
        }
    }
    for w in workers {
        let _ = w.join();
    }
    collected.sort_by_key(|(idx, _)| *idx);

    {
        let mut p = progress.write();
        p.tested = collected.len();
        p.succeeded = collected.iter().filter(|(_, r)| r.success).count();
        p.failed = collected.len() - p.succeeded;
        p.results = collected.into_iter().map(|(_, r)| r).collect();
        p.is_running = false;
        p.is_completed = true;
    }
}

/// Probe one Warp endpoint.
///
/// Warp runs WireGuard over UDP, so a genuine handshake initiation is the
/// honest test (see wireguard.rs). But many networks silently drop UDP
/// (no ICMP unreachable), which would make every endpoint look equally
/// "timed out". Strategy:
///  1. UDP probe with a real 148-byte handshake initiation. Only a valid
///     92-byte handshake response counts as success.
///  2. If UDP times out with NO reply at all, fall back to a TCP connect
///     on the same port: open TCP = host reachable (routing OK), even if
///     the Warp UDP service itself is filtered. Closed/refused TCP is
///     still a signal (host up, port filtered).
fn probe_warp_endpoint(ip: &str, port: u16, timeout_ms: u64) -> WarpResult {
    let endpoint = format!("{ip}:{port}");
    let timeout = Duration::from_millis(timeout_ms);

    // --- Step 1: UDP probe ---
    let udp_outcome = udp_probe(ip, port, timeout);

    match udp_outcome {
        UdpOutcome::Replied(rtt) => WarpResult {
            ip: ip.to_string(),
            port,
            endpoint,
            rtt_ms: rtt,
            success: true,
            // Genuine WireGuard handshake completed (not the old "any
            // bytes back" heuristic) — the UI renders these distinctly.
            error: Some("WireGuard handshake".to_string()),
        },
        UdpOutcome::Refused(rtt) => WarpResult {
            // Host answered (ICMP port unreachable) but Warp UDP is closed.
            ip: ip.to_string(),
            port,
            endpoint,
            rtt_ms: rtt,
            success: false,
            error: Some("UDP port unreachable (host up)".to_string()),
        },
        UdpOutcome::Timeout => {
            // --- Step 2: TCP fallback on same port ---
            match tcp_probe(ip, port, timeout) {
                Some(rtt) => WarpResult {
                    ip: ip.to_string(),
                    port,
                    endpoint,
                    rtt_ms: rtt,
                    success: true,
                    error: Some("via TCP fallback (UDP filtered)".to_string()),
                },
                None => WarpResult {
                    ip: ip.to_string(),
                    port,
                    endpoint,
                    rtt_ms: -1.0,
                    success: false,
                    error: Some("timeout (UDP silent, TCP closed)".to_string()),
                },
            }
        }
    }
}

enum UdpOutcome {
    /// Valid WireGuard handshake response received (cryptographic proof
    /// of a live peer — never stray bytes).
    Replied(f64),
    /// ICMP port-unreachable / connection refused: host is up.
    Refused(f64),
    /// Silence for the whole timeout.
    Timeout,
}

/// Builds a socket address without string round-tripping: `format!` +
/// `parse` breaks on bare IPv6 (`::1:443` is ambiguous), while parsing the
/// IP literal first handles both families explicitly.
fn parse_target(ip: &str, port: u16) -> Option<SocketAddr> {
    let parsed: std::net::IpAddr = ip.parse().ok()?;
    Some(SocketAddr::new(parsed, port))
}

fn udp_probe(ip: &str, port: u16, timeout: Duration) -> UdpOutcome {
    let addr = match parse_target(ip, port) {
        Some(a) => a,
        None => return UdpOutcome::Timeout,
    };

    // Bind an ephemeral local UDP socket matching the address family: an
    // IPv4-bound socket cannot reach IPv6 destinations (and vice versa
    // without dual-stack), which silently broke every IPv6 endpoint before.
    let bind_addr = if addr.is_ipv6() {
        "[::]:0"
    } else {
        "0.0.0.0:0"
    };
    let sock = match UdpSocket::bind(bind_addr) {
        Ok(s) => s,
        Err(_) => return UdpOutcome::Timeout,
    };
    if sock.set_read_timeout(Some(timeout)).is_err() {
        return UdpOutcome::Timeout;
    }

    // Genuine 148-byte WireGuard handshake initiation (see wireguard.rs).
    // Real peers answer with a 92-byte handshake response; anything else
    // (including the old 32-byte random blob approach, which servers drop
    // silently) can never confirm a WireGuard endpoint.
    let (packet, sender_index) =
        match crate::wireguard::build_handshake_init(&crate::wireguard::DEFAULT_WARP_PEER_KEY) {
            Some(v) => v,
            None => return UdpOutcome::Timeout,
        };

    let start = Instant::now();
    if sock.send_to(&packet, addr).is_err() {
        return UdpOutcome::Timeout;
    }

    // Wait out the full timeout, validating candidates: only a proper
    // handshake response counts. Stray bytes are ignored, not scored.
    let mut buf = [0u8; 1500];
    loop {
        if start.elapsed() >= timeout {
            return UdpOutcome::Timeout;
        }
        match sock.recv_from(&mut buf) {
            Ok((n, _)) => {
                if crate::wireguard::is_handshake_response(&buf[..n], sender_index) {
                    return UdpOutcome::Replied(start.elapsed().as_secs_f64() * 1000.0);
                }
                // else: empty/stray packet, keep waiting for the reply.
            }
            // Host answered with ICMP port-unreachable. NOTE: Windows reports
            // this as WSAECONNRESET (ConnectionReset), POSIX as
            // ECONNREFUSED (ConnectionRefused) — both mean "host is up, Warp
            // UDP port is closed". Matching only one of them (as before) made
            // the Refused branch dead on the other platform.
            Err(e)
                if e.kind() == std::io::ErrorKind::ConnectionRefused
                    || e.kind() == std::io::ErrorKind::ConnectionReset =>
            {
                return UdpOutcome::Refused(start.elapsed().as_secs_f64() * 1000.0);
            }
            // Interrupted syscalls retry; any other error (incl.
            // WouldBlock after the full read timeout) ends the wait —
            // the recv already waited out the deadline.
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return UdpOutcome::Timeout,
        }
    }
}

fn tcp_probe(ip: &str, port: u16, timeout: Duration) -> Option<f64> {
    let addr = parse_target(ip, port)?;
    let start = Instant::now();
    match std::net::TcpStream::connect_timeout(&addr, timeout) {
        Ok(s) => {
            drop(s);
            Some(start.elapsed().as_secs_f64() * 1000.0)
        }
        Err(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_target_v4_v6_invalid() {
        let v4 = parse_target("162.159.192.1", 443).expect("v4 parses");
        assert!(!v4.ip().is_ipv6());
        assert_eq!(v4.port(), 443);

        // Bracket-stripped IPv6 (CSV layer removes brackets first).
        let v6 = parse_target("::1", 443).expect("v6 parses");
        assert!(v6.ip().is_ipv6());
        assert_eq!(v6.port(), 443);

        // The old `format!("{ip}:{port}").parse()` path returned these
        // as Timeout; explicit IP parsing must not.
        assert!(parse_target("2001:db8::1", 864).is_some());
        assert!(parse_target("not-an-ip", 443).is_none());
        assert!(parse_target("", 443).is_none());
    }
}

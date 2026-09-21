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

/// Shared work queue: `(original index, (ip, port))` pairs for warp workers.
type JobQueue = Arc<RwLock<Vec<(usize, (String, u16))>>>;

pub struct WarpManager {
    sessions: Arc<RwLock<HashMap<u32, Arc<RwLock<WarpProgress>>>>>,
    cancel_flags: Arc<RwLock<HashMap<u32, Arc<AtomicBool>>>>,
    next_session_id: AtomicU32,
}

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
    pub fn start_scan(
        &self,
        endpoints: Vec<(String, u16)>,
        parallel: u32,
        timeout_ms: u32,
    ) -> u32 {
        let session_id = self.next_session_id.fetch_add(1, Ordering::SeqCst);
        let parallel = parallel.clamp(1, 64) as usize;
        let timeout_ms = (if timeout_ms == 0 { 1200 } else { timeout_ms.min(5000) }) as u64;

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
        self.cancel_flags.write().insert(session_id, cancel_flag.clone());

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
    let queue: JobQueue = Arc::new(RwLock::new(
        endpoints.into_iter().enumerate().collect(),
    ));

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
    let mut collected: Vec<(usize, WarpResult)> = Vec::new();
    for (idx, res) in rx {
        collected.push((idx, res));
        if cancel_flag.load(Ordering::SeqCst) {
            break;
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
/// Warp runs WireGuard over UDP, so a UDP handshake-shaped probe is the
/// honest test. But many networks silently drop UDP (no ICMP unreachable),
/// which would make every endpoint look equally "timed out". Strategy:
///  1. UDP probe with a 32-byte WireGuard-style initiation payload.
///     Any UDP reply (even unreachable) + fast timing = reachable.
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
            error: None,
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
    /// Got bytes back (WireGuard reply or anything at all).
    Replied(f64),
    /// ICMP port-unreachable / connection refused: host is up.
    Refused(f64),
    /// Silence for the whole timeout.
    Timeout,
}

fn udp_probe(ip: &str, port: u16, timeout: Duration) -> UdpOutcome {
    let addr: SocketAddr = match format!("{ip}:{port}").parse() {
        Ok(a) => a,
        Err(_) => return UdpOutcome::Timeout,
    };

    // Bind an ephemeral local UDP socket.
    let sock = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return UdpOutcome::Timeout,
    };
    if sock.set_read_timeout(Some(timeout)).is_err() {
        return UdpOutcome::Timeout;
    }

    // 32-byte WireGuard handshake-initiation-shaped payload:
    // byte[0] = message type 1 (handshake initiation), rest pseudo-random.
    // Real Warp servers reply (or at least RST/ICMP) quickly if reachable.
    let mut payload = [0u8; 32];
    payload[0] = 1;
    // Cheap xorshift filler so middleboxes can't fingerprint a static blob.
    let mut x: u64 = (ip.len() as u64)
        .wrapping_mul(0x9E3779B97F4A7C15)
        .wrapping_add(port as u64)
        .wrapping_add(now_nanos());
    for b in payload.iter_mut().skip(1) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        *b = (x & 0xFF) as u8;
    }

    let start = Instant::now();
    if sock.send_to(&payload, addr).is_err() {
        return UdpOutcome::Timeout;
    }

    let mut buf = [0u8; 1500];
    match sock.recv_from(&mut buf) {
        Ok((n, _)) if n > 0 => {
            UdpOutcome::Replied(start.elapsed().as_secs_f64() * 1000.0)
        }
        Ok(_) => UdpOutcome::Timeout,
        Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
            UdpOutcome::Refused(start.elapsed().as_secs_f64() * 1000.0)
        }
        Err(_) => UdpOutcome::Timeout,
    }
}

fn tcp_probe(ip: &str, port: u16, timeout: Duration) -> Option<f64> {
    let addr: SocketAddr = format!("{ip}:{port}").parse().ok()?;
    let start = Instant::now();
    match std::net::TcpStream::connect_timeout(&addr, timeout) {
        Ok(s) => {
            drop(s);
            Some(start.elapsed().as_secs_f64() * 1000.0)
        }
        Err(_) => None,
    }
}

fn now_nanos() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

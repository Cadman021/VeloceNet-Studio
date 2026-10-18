use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
// Only consumed inside the #[cfg(windows)] module (via `use super::*`);
// ungated, they warn as unused on Linux/macOS builds.
#[cfg(windows)]
use std::ffi::c_void;
#[cfg(windows)]
use std::mem::size_of;
use std::net::{IpAddr, Ipv4Addr, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Duration;
// Only consumed inside the #[cfg(windows)] module (via `use super::*`);
// ungated, it warns as unused on Linux/macOS builds.
#[cfg(windows)]
use std::time::Instant;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HopInfo {
    pub hop_num: u8,
    pub ip: String,
    pub hostname: Option<String>,
    pub rtt_ms: f64,
    pub is_timeout: bool,
    pub reached_destination: bool,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TracerouteProgress {
    pub session_id: u32,
    pub target_host: String,
    pub target_ip: String,
    pub max_hops: u8,
    pub current_hop: u8,
    pub is_running: bool,
    pub is_completed: bool,
    pub error: Option<String>,
    pub hops: Vec<HopInfo>,
}

#[cfg(windows)]
mod win_icmp {
    use super::*;
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        IcmpSendEcho, IP_BAD_DESTINATION, IP_DEST_HOST_UNREACHABLE, IP_DEST_NET_UNREACHABLE,
        IP_DEST_PORT_UNREACHABLE, IP_DEST_PROT_UNREACHABLE, IP_OPTION_INFORMATION,
        IP_REQ_TIMED_OUT, IP_SUCCESS, IP_TTL_EXPIRED_REASSEM, IP_TTL_EXPIRED_TRANSIT,
    };

    #[repr(C)]
    struct IcmpEchoReply {
        address: u32,
        status: u32,
        round_trip_time: u32,
        data_size: u16,
        reserved: u16,
        data: *mut c_void,
        options: IP_OPTION_INFORMATION,
    }

    /// Statuses meaning "no route to the target": the trace should end here
    /// (the hop is shown, but it is not a destination hit).
    fn is_terminal_unreachable(status: u32) -> bool {
        matches!(
            status,
            IP_DEST_NET_UNREACHABLE
                | IP_DEST_HOST_UNREACHABLE
                | IP_DEST_PROT_UNREACHABLE
                | IP_DEST_PORT_UNREACHABLE
                | IP_BAD_DESTINATION
        )
    }

    #[allow(clippy::type_complexity)]
    pub fn probe_hop_on_handle(
        handle: HANDLE,
        dest_ip_u32: u32,
        ttl: u8,
        timeout_ms: u32,
    ) -> (Option<Ipv4Addr>, f64, bool, bool, bool, String) {
        unsafe {
            let send_data = b"NetStudioVisualTracerouteHopData";
            let reply_buf_size = size_of::<IcmpEchoReply>() + send_data.len() + 32;
            let mut reply_buf = vec![0u8; reply_buf_size];

            let mut options = IP_OPTION_INFORMATION {
                Ttl: ttl,
                Tos: 0,
                Flags: 0,
                OptionsSize: 0,
                OptionsData: std::ptr::null_mut(),
            };

            let start = Instant::now();
            let replies_count = IcmpSendEcho(
                handle,
                dest_ip_u32,
                send_data.as_ptr() as *const c_void,
                send_data.len() as u16,
                &mut options as *mut IP_OPTION_INFORMATION,
                reply_buf.as_mut_ptr() as *mut c_void,
                reply_buf_size as u32,
                timeout_ms,
            );
            let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;

            if replies_count > 0 {
                let reply = &*(reply_buf.as_ptr() as *const IcmpEchoReply);
                // reply.address is a u32 in network byte order, i.e. its
                // numeric value is (o1<<24)|(o2<<16)|(o3<<8)|o4 (same
                // convention as u32::from(Ipv4Addr) / Ipv4Addr::from(u32)).
                // to_be_bytes() recovers [o1,o2,o3,o4] on any platform.
                let octets = reply.address.to_be_bytes();
                let hop_ip = Ipv4Addr::new(octets[0], octets[1], octets[2], octets[3]);
                let rtt = if reply.round_trip_time == 0 {
                    elapsed_ms.max(0.2)
                } else {
                    reply.round_trip_time as f64
                };

                if reply.status == IP_SUCCESS {
                    // Reached destination
                    (
                        Some(hop_ip),
                        rtt,
                        false,
                        true,
                        false,
                        "Destination Reached".to_string(),
                    )
                } else if reply.status == IP_TTL_EXPIRED_TRANSIT
                    || reply.status == IP_TTL_EXPIRED_REASSEM
                {
                    // Router in transit
                    (
                        Some(hop_ip),
                        rtt,
                        false,
                        false,
                        false,
                        "Time Exceeded in Transit".to_string(),
                    )
                } else if reply.status == IP_REQ_TIMED_OUT {
                    // Some Windows paths return a reply record whose status
                    // is a timeout; do not count it as a real sample.
                    (
                        None,
                        -1.0,
                        true,
                        false,
                        false,
                        "Request Timed Out".to_string(),
                    )
                } else if is_terminal_unreachable(reply.status) {
                    // Router reports the destination (or its network/port)
                    // unreachable: stop walking TTLs instead of spraying
                    // doomed probes up to max_hops.
                    (
                        Some(hop_ip),
                        rtt,
                        false,
                        false,
                        true,
                        "Destination Unreachable".to_string(),
                    )
                } else {
                    // Other ICMP response status
                    (
                        Some(hop_ip),
                        rtt,
                        false,
                        false,
                        false,
                        format!("ICMP Status {}", reply.status),
                    )
                }
            } else {
                // Timeout / Packet Loss
                (
                    None,
                    -1.0,
                    true,
                    false,
                    false,
                    "Request Timed Out".to_string(),
                )
            }
        }
    }
}

/// One TTL-scoped probe on Linux/macOS: echo request with `ttl`; accepts
/// the destination's echo reply (reached) or a TTL-expired/unreachable
/// ICMP error from a router (transit). Same tuple shape as the Windows
/// probe so the worker loop stays platform-agnostic.
#[cfg(unix)]
#[allow(clippy::type_complexity)]
fn unix_probe_hop(
    sock: &mut crate::probe::unix_icmp::IcmpSocket,
    dest: Ipv4Addr,
    ttl: u8,
    timeout_ms: u32,
) -> (Option<Ipv4Addr>, f64, bool, bool, bool, String) {
    use crate::probe::unix_icmp::{ReplyKind, WaitOutcome};

    let seq = match sock.send_echo(dest, ttl) {
        Ok(s) => s,
        Err(e) => {
            return (
                None,
                -1.0,
                true,
                false,
                false,
                format!("ICMP send failed: {}", e),
            )
        }
    };
    match sock.wait_reply(dest, seq, Duration::from_millis(timeout_ms as u64)) {
        WaitOutcome::Reply(r) => {
            let reached = r.kind == ReplyKind::EchoReply || r.from == dest;
            let (status, terminal) = match r.kind {
                ReplyKind::EchoReply => ("Destination Reached", false),
                ReplyKind::TimeExceeded => ("Time Exceeded in Transit", false),
                ReplyKind::Unreachable if reached => ("Destination Reached", false),
                ReplyKind::Unreachable => ("Destination Unreachable", true),
            };
            (
                Some(r.from),
                r.rtt_ms,
                false,
                reached,
                terminal,
                status.to_string(),
            )
        }
        WaitOutcome::Timeout => (
            None,
            -1.0,
            true,
            false,
            false,
            "Request Timed Out".to_string(),
        ),
    }
}

/// Brackets bare IPv6 literals before appending a port; traceroute itself
/// is IPv4-only, but a v6 literal must fail with "no IPv4 address" rather
/// than an unparsable `::1:0`.
fn host_with_port(host: &str, port: u16) -> String {
    if host.contains(':') && !host.starts_with('[') {
        format!("[{}]:{}", host, port)
    } else {
        format!("{}:{}", host, port)
    }
}

pub struct TracerouteManager {
    sessions: Arc<RwLock<HashMap<u32, Arc<RwLock<TracerouteProgress>>>>>,
    cancel_flags: Arc<RwLock<HashMap<u32, Arc<AtomicBool>>>>,
    next_session_id: AtomicU32,
}

/// Max concurrent sessions: each spawns a worker thread, and sessions only
/// vanish on explicit free — unbounded starts would leak threads forever.
pub const MAX_TRACEROUTE_SESSIONS: usize = 8;

impl Default for TracerouteManager {
    fn default() -> Self {
        Self::new()
    }
}

impl TracerouteManager {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            cancel_flags: Arc::new(RwLock::new(HashMap::new())),
            next_session_id: AtomicU32::new(1),
        }
    }

    pub fn start_traceroute(&self, host: String, max_hops: u8, timeout_ms: u32) -> u32 {
        // Prune finished sessions first so a forgotten free() can't wedge
        // the manager at the cap; refuse only when truly full. Both maps
        // are pruned together (flags would otherwise leak one entry per
        // finished session).
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
        if self.sessions.read().len() >= MAX_TRACEROUTE_SESSIONS {
            return 0;
        }
        let session_id = self.next_session_id.fetch_add(1, Ordering::SeqCst);
        let max_hops = if max_hops == 0 || max_hops > 64 {
            30
        } else {
            max_hops
        };
        let timeout_ms = if timeout_ms == 0 {
            1500
        } else {
            timeout_ms.min(5000)
        };

        let progress = Arc::new(RwLock::new(TracerouteProgress {
            session_id,
            target_host: host.clone(),
            target_ip: String::new(),
            max_hops,
            current_hop: 0,
            is_running: true,
            is_completed: false,
            error: None,
            hops: Vec::new(),
        }));

        let cancel_flag = Arc::new(AtomicBool::new(false));

        self.sessions.write().insert(session_id, progress.clone());
        self.cancel_flags
            .write()
            .insert(session_id, cancel_flag.clone());

        // Spawn background worker thread for stepping through hops
        std::thread::spawn(move || {
            Self::run_traceroute_worker(host, max_hops, timeout_ms, progress, cancel_flag);
        });

        session_id
    }

    pub fn poll_progress_json(&self, session_id: u32) -> Option<String> {
        let sessions = self.sessions.read();
        if let Some(prog) = sessions.get(&session_id) {
            let snap = prog.read().clone();
            serde_json::to_string(&snap).ok()
        } else {
            None
        }
    }

    pub fn stop_traceroute(&self, session_id: u32) -> bool {
        let cancel_flags = self.cancel_flags.read();
        if let Some(flag) = cancel_flags.get(&session_id) {
            flag.store(true, Ordering::SeqCst);
            if let Some(prog) = self.sessions.read().get(&session_id) {
                let mut p = prog.write();
                p.is_running = false;
                p.is_completed = true;
            }
            true
        } else {
            false
        }
    }

    pub fn free_session(&self, session_id: u32) {
        self.stop_traceroute(session_id);
        self.sessions.write().remove(&session_id);
        self.cancel_flags.write().remove(&session_id);
    }

    fn run_traceroute_worker(
        host: String,
        max_hops: u8,
        timeout_ms: u32,
        progress: Arc<RwLock<TracerouteProgress>>,
        cancel_flag: Arc<AtomicBool>,
    ) {
        // Step 1: Resolve DNS to IPv4
        let target_socket_addr = match host_with_port(&host, 0).to_socket_addrs() {
            Ok(mut iter) => match iter.find(|sa| sa.is_ipv4()) {
                Some(sa) => sa,
                None => {
                    let mut p = progress.write();
                    p.is_running = false;
                    p.is_completed = true;
                    p.error = Some("No IPv4 address resolved for target".to_string());
                    return;
                }
            },
            Err(e) => {
                let mut p = progress.write();
                p.is_running = false;
                p.is_completed = true;
                p.error = Some(format!("DNS resolution failed: {}", e));
                return;
            }
        };

        let target_ipv4 = match target_socket_addr.ip() {
            IpAddr::V4(v4) => v4,
            _ => {
                let mut p = progress.write();
                p.is_running = false;
                p.is_completed = true;
                p.error = Some("Target is not IPv4".to_string());
                return;
            }
        };

        // IcmpSendEcho takes DestinationAddress as IPAddr (a u32 in
        // network byte order: value (o1<<24)|(o2<<16)|(o3<<8)|o4, same
        // convention as u32::from(Ipv4Addr)). from_be_bytes builds that
        // numeric value from the dotted-quad octets on any platform.
        #[cfg(windows)]
        let dest_ip_u32 = u32::from_be_bytes(target_ipv4.octets());
        {
            let mut p = progress.write();
            p.target_ip = target_ipv4.to_string();
        }

        // Step 2: Loop TTL from 1 up to max_hops.
        // NOTE: a single ICMP handle is reused for all TTLs. The previous
        // version opened/closed a new handle per TTL, which broke
        // TTL-expired replies on Windows.
        #[cfg(windows)]
        let handle: windows_sys::Win32::Foundation::HANDLE =
            unsafe { windows_sys::Win32::NetworkManagement::IpHelper::IcmpCreateFile() };
        #[cfg(windows)]
        if handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE || handle.is_null() {
            let mut p = progress.write();
            p.is_running = false;
            p.is_completed = true;
            p.error = Some("Failed to open ICMP handle".to_string());
            return;
        }

        // Linux/macOS: one unprivileged ping socket for the whole trace
        // (SOCK_DGRAM, IPPROTO_ICMP — no root needed where ping sockets
        // are permitted). TTL-expired replies arrive via the Linux error
        // queue or as normal datagrams on macOS.
        #[cfg(unix)]
        let mut unix_sock = match crate::probe::unix_icmp::IcmpSocket::open() {
            Ok(s) => s,
            Err(e) => {
                let mut p = progress.write();
                p.is_running = false;
                p.is_completed = true;
                p.error = Some(format!("ICMP unavailable: {}", e));
                return;
            }
        };

        for ttl in 1..=max_hops {
            if cancel_flag.load(Ordering::SeqCst) {
                break;
            }

            {
                let mut p = progress.write();
                p.current_hop = ttl;
            }

            // Probe with specific TTL on the shared handle, 3 samples
            // like the system `tracert` (single samples spike: one slow
            // router used to define the whole hop's RTT).
            let mut samples = 0u32;
            let mut rtt_sum = 0.0;
            let mut hop_ip_opt = None;
            let mut reached_dest = false;
            let mut terminal_unreachable = false;
            let mut status = "Request Timed Out".to_string();
            for _ in 0..3 {
                if cancel_flag.load(Ordering::SeqCst) {
                    break;
                }
                let (ip, rtt, timed_out, reached, terminal, s) = {
                    #[cfg(windows)]
                    {
                        win_icmp::probe_hop_on_handle(handle, dest_ip_u32, ttl, timeout_ms)
                    }
                    #[cfg(unix)]
                    {
                        unix_probe_hop(&mut unix_sock, target_ipv4, ttl, timeout_ms)
                    }
                    #[cfg(not(any(windows, unix)))]
                    {
                        (
                            None,
                            -1.0,
                            true,
                            false,
                            false,
                            "Unsupported platform".to_string(),
                        )
                    }
                };
                if !timed_out {
                    samples += 1;
                    rtt_sum += rtt;
                    if hop_ip_opt.is_none() {
                        hop_ip_opt = ip;
                    }
                    reached_dest = reached_dest || reached;
                    terminal_unreachable = terminal_unreachable || terminal;
                    status = s;
                }
            }
            let (rtt, is_timeout) = if samples > 0 {
                (rtt_sum / samples as f64, false)
            } else {
                (-1.0, true)
            };

            let (ip_str, reached_final) = match hop_ip_opt {
                Some(ip) => {
                    let is_dest = reached_dest || ip == target_ipv4;
                    (ip.to_string(), is_dest)
                }
                None => ("*".to_string(), false),
            };

            let hop_info = HopInfo {
                hop_num: ttl,
                ip: ip_str,
                hostname: None,
                rtt_ms: rtt,
                is_timeout,
                reached_destination: reached_final,
                status,
            };

            {
                let mut p = progress.write();
                p.hops.push(hop_info);
            }

            if reached_final {
                // Reached target destination!
                break;
            }
            if terminal_unreachable {
                // A router declared the destination unreachable: further
                // TTLs cannot succeed, stop the trace at this hop.
                break;
            }

            // Small delay between hops to avoid flood
            std::thread::sleep(Duration::from_millis(60));
        }

        #[cfg(windows)]
        unsafe {
            windows_sys::Win32::NetworkManagement::IpHelper::IcmpCloseHandle(handle)
        };

        {
            let mut p = progress.write();
            p.is_running = false;
            p.is_completed = true;
        }
    }
}

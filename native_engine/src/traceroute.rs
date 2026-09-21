use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::c_void;
use std::mem::size_of;
use std::net::{IpAddr, Ipv4Addr, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

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
        IcmpSendEcho, IP_OPTION_INFORMATION,
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

    const IP_SUCCESS: u32 = 0;
    const IP_TTL_EXPIRED_TRANSIT: u32 = 11013;
    const IP_TTL_EXPIRED_REASSEM: u32 = 11014;

    pub fn probe_hop_on_handle(handle: HANDLE, dest_ip_u32: u32, ttl: u8, timeout_ms: u32) -> (Option<Ipv4Addr>, f64, bool, bool, String) {
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
                    if elapsed_ms < 1.0 { elapsed_ms.max(0.2) } else { 0.5 }
                } else {
                    reply.round_trip_time as f64
                };

                if reply.status == IP_SUCCESS {
                    // Reached destination
                    (Some(hop_ip), rtt, false, true, "Destination Reached".to_string())
                } else if reply.status == IP_TTL_EXPIRED_TRANSIT || reply.status == IP_TTL_EXPIRED_REASSEM {
                    // Router in transit
                    (Some(hop_ip), rtt, false, false, "Time Exceeded in Transit".to_string())
                } else {
                    // Other ICMP response status
                    (Some(hop_ip), rtt, false, false, format!("ICMP Status {}", reply.status))
                }
            } else {
                // Timeout / Packet Loss
                (None, -1.0, true, false, "Request Timed Out".to_string())
            }
        }
    }
}

#[cfg(not(windows))]
mod win_icmp {
    use super::*;

    pub fn probe_hop_on_handle(_handle: usize, _dest_ip_u32: u32, _ttl: u8, _timeout_ms: u32) -> (Option<Ipv4Addr>, f64, bool, bool, String) {
        (None, -1.0, true, false, "Non-Windows platform fallback".to_string())
    }
}

pub struct TracerouteManager {
    sessions: Arc<RwLock<HashMap<u32, Arc<RwLock<TracerouteProgress>>>>>,
    cancel_flags: Arc<RwLock<HashMap<u32, Arc<AtomicBool>>>>,
    next_session_id: AtomicU32,
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
        let session_id = self.next_session_id.fetch_add(1, Ordering::SeqCst);
        let max_hops = if max_hops == 0 || max_hops > 64 { 30 } else { max_hops };
        let timeout_ms = if timeout_ms == 0 { 1500 } else { timeout_ms.min(5000) };

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
        self.cancel_flags.write().insert(session_id, cancel_flag.clone());

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
        let target_socket_addr = match format!("{}:0", host).to_socket_addrs() {
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
        if handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE || handle == 0 {
            let mut p = progress.write();
            p.is_running = false;
            p.is_completed = true;
            p.error = Some("Failed to open ICMP handle".to_string());
            return;
        }
        #[cfg(not(windows))]
        let handle: usize = 0;

        for ttl in 1..=max_hops {
            if cancel_flag.load(Ordering::SeqCst) {
                break;
            }

            {
                let mut p = progress.write();
                p.current_hop = ttl;
            }

            // Probe with specific TTL on the shared handle
            let (hop_ip_opt, rtt, is_timeout, reached_dest, status) =
                win_icmp::probe_hop_on_handle(handle, dest_ip_u32, ttl, timeout_ms);

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

            // Small delay between hops to avoid flood
            std::thread::sleep(Duration::from_millis(60));
        }

        #[cfg(windows)]
        unsafe { windows_sys::Win32::NetworkManagement::IpHelper::IcmpCloseHandle(handle) };

        {
            let mut p = progress.write();
            p.is_running = false;
            p.is_completed = true;
        }
    }
}

use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

/// One interface sample (cumulative counters from the OS).
#[derive(Debug, Clone, Default)]
struct IfCounters {
    name: String,
    alias: String,
    in_octets: u64,
    out_octets: u64,
    speed_bps: u64,
    is_up: bool,
}

/// Per-process traffic estimate for the current sampling window.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessTraffic {
    pub pid: u32,
    pub name: String,
    pub protocol: String,
    pub up_bps: f64,
    pub down_bps: f64,
    pub total_bps: f64,
    pub connections: u32,
}

/// One bandwidth snapshot returned to Flutter as JSON.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BandwidthSnapshot {
    pub timestamp_ms: u64,
    pub up_bps: f64,
    pub down_bps: f64,
    pub total_bps: f64,
    pub interfaces: Vec<InterfaceStat>,
    pub top_processes: Vec<ProcessTraffic>,
    pub is_estimated: bool,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InterfaceStat {
    pub name: String,
    pub alias: String,
    pub up_bps: f64,
    pub down_bps: f64,
    pub total_bps: f64,
    pub speed_bps: u64,
    pub is_up: bool,
}

impl BandwidthSnapshot {
    fn empty(note: &str) -> Self {
        Self {
            timestamp_ms: now_ms(),
            up_bps: 0.0,
            down_bps: 0.0,
            total_bps: 0.0,
            interfaces: Vec::new(),
            top_processes: Vec::new(),
            is_estimated: true,
            note: Some(note.to_string()),
        }
    }
}

fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub struct BandwidthMonitor {
    running: Arc<AtomicBool>,
    worker: parking_lot::Mutex<Option<std::thread::JoinHandle<()>>>,
    latest: Arc<RwLock<BandwidthSnapshot>>,
}

impl Default for BandwidthMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl BandwidthMonitor {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            worker: parking_lot::Mutex::new(None),
            latest: Arc::new(RwLock::new(BandwidthSnapshot::empty("not started"))),
        }
    }

    pub fn start(&self, interval_ms: u64) {
        if self.running.swap(true, Ordering::SeqCst) {
            return; // already running
        }
        let interval = interval_ms.clamp(500, 5000);
        let running = self.running.clone();
        let latest = self.latest.clone();

        let handle = std::thread::spawn(move || {
            let mut prev: HashMap<String, IfCounters> = HashMap::new();
            let mut prev_time: Option<Instant> = None;
            let mut first = true;

            while running.load(Ordering::SeqCst) {
                let now = Instant::now();
                let current = read_interface_counters();

                if let Some(prev_t) = prev_time {
                    let dt = now.duration_since(prev_t).as_secs_f64();
                    if dt > 0.05 && !current.is_empty() {
                        let snap = build_snapshot(&prev, &current, dt, first);
                        *latest.write() = snap;
                        first = false;
                    }
                }

                prev = current
                    .into_iter()
                    .map(|c| (c.name.clone(), c))
                    .collect();
                prev_time = Some(now);

                std::thread::sleep(std::time::Duration::from_millis(interval));
            }
        });

        *self.worker.lock() = Some(handle);
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(h) = self.worker.lock().take() {
            let _ = h.join();
        }
    }

    pub fn snapshot_json(&self) -> String {
        let snap = self.latest.read().clone();
        serde_json::to_string(&snap).unwrap_or_else(|_| "{}".to_string())
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }
}

fn build_snapshot(
    prev: &HashMap<String, IfCounters>,
    current: &[IfCounters],
    dt_secs: f64,
    first_sample: bool,
) -> BandwidthSnapshot {
    let mut interfaces = Vec::new();
    let mut total_up = 0.0;
    let mut total_down = 0.0;

    for cur in current {
        // Keep down interfaces OUT of the totals (they report stale
        // counters) but still list them so the UI can show their state.
        // Skip loopback / virtual noise entirely.
        let lname = cur.name.to_lowercase();
        if lname.contains("loopback") || lname.contains("loobpack") {
            continue;
        }
        let counts_toward_totals = cur.is_up;

        let (up_bps, down_bps) = match prev.get(&cur.name) {
            Some(p) => {
                let d_in = cur.in_octets.saturating_sub(p.in_octets) as f64;
                let d_out = cur.out_octets.saturating_sub(p.out_octets) as f64;
                // Counter reset (reboot/reconnect) shows as huge spike; clamp it.
                let down = (d_in * 8.0 / dt_secs).min(10_000_000_000.0);
                let up = (d_out * 8.0 / dt_secs).min(10_000_000_000.0);
                (up, down)
            }
            None => (0.0, 0.0),
        };

        if counts_toward_totals {
            total_up += up_bps;
            total_down += down_bps;
        }

        interfaces.push(InterfaceStat {
            name: cur.name.clone(),
            alias: cur.alias.clone(),
            up_bps,
            down_bps,
            total_bps: up_bps + down_bps,
            speed_bps: cur.speed_bps,
            is_up: cur.is_up,
        });
    }

    interfaces.sort_by(|a, b| {
        b.total_bps
            .partial_cmp(&a.total_bps)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let top_processes = read_process_traffic(total_up, total_down);

    BandwidthSnapshot {
        timestamp_ms: now_ms(),
        up_bps: total_up,
        down_bps: total_down,
        total_bps: total_up + total_down,
        interfaces,
        top_processes,
        is_estimated: first_sample,
        note: if first_sample {
            Some("warming up — first delta".to_string())
        } else {
            None
        },
    }
}

// ---------------------------------------------------------------------------
// Platform readers
// ---------------------------------------------------------------------------

#[cfg(windows)]
fn read_interface_counters() -> Vec<IfCounters> {
    read_interface_counters_win()
}

#[cfg(not(windows))]
fn read_interface_counters() -> Vec<IfCounters> {
    read_interface_counters_fallback()
}

#[cfg(windows)]
fn read_process_traffic(total_up: f64, total_down: f64) -> Vec<ProcessTraffic> {
    read_process_traffic_win(total_up, total_down)
}

#[cfg(not(windows))]
fn read_process_traffic(_total_up: f64, _total_down: f64) -> Vec<ProcessTraffic> {
    Vec::new()
}

// ---------------- Windows: GetIfTable2 (64-bit counters) ----------------
#[cfg(windows)]
fn read_interface_counters_win() -> Vec<IfCounters> {
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        FreeMibTable, GetIfTable2, MIB_IF_TABLE2,
    };
    use windows_sys::Win32::NetworkManagement::Ndis::IfOperStatusUp;

    // NOTE: the old code used GetIfTable (MIB_IFROW) whose dwInOctets /
    // dwOutOctets are u32 and wrap every 4 GiB — on a gigabit link that is
    // roughly every 30 s, so deltas were constantly wrong. GetIfTable2
    // exposes 64-bit InOctets/OutOctets plus a real link speed and UTF-16
    // friendly names.
    unsafe {
        let mut table: *mut MIB_IF_TABLE2 = std::ptr::null_mut();
        if GetIfTable2(&mut table) != 0 || table.is_null() {
            return Vec::new();
        }

        let count = (*table).NumEntries as usize;
        let rows = (*table).Table.as_ptr();
        let mut out = Vec::with_capacity(count);

        for i in 0..count {
            let row = &*rows.add(i);
            let alias = decode_wide(&row.Alias);
            let descr = decode_wide(&row.Description);
            // IfOperStatusUp == 1. Anything else (down, dormant, testing…)
            // reports stale counters, so it is listed but excluded from totals.
            let is_up = row.OperStatus == IfOperStatusUp;
            let label = if !alias.is_empty() {
                alias.clone()
            } else if !descr.is_empty() {
                descr.clone()
            } else {
                format!("if{}", row.InterfaceIndex)
            };
            out.push(IfCounters {
                alias,
                name: format!("if{} {}", row.InterfaceIndex, label),
                in_octets: row.InOctets,
                out_octets: row.OutOctets,
                speed_bps: row.TransmitLinkSpeed,
                is_up,
            });
        }

        FreeMibTable(table as *mut std::ffi::c_void);
        out
    }
}

/// Decodes a NUL-terminated UTF-16 WCHAR buffer (e.g. `MIB_IF_ROW2::Alias`).
#[cfg(windows)]
fn decode_wide(buf: &[u16]) -> String {
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..len]).trim().to_string()
}

// ---------------- Windows: per-process via TCP/UDP tables ----------------
#[cfg(windows)]
fn read_process_traffic_win(total_up: f64, total_down: f64) -> Vec<ProcessTraffic> {
    use std::collections::HashMap;
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        GetExtendedTcpTable, GetExtendedUdpTable, MIB_TCPROW_OWNER_PID,
        MIB_UDPROW_OWNER_PID, TCP_TABLE_OWNER_PID_ALL, UDP_TABLE_OWNER_PID,
    };
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32First, Process32Next, PROCESSENTRY32,
        TH32CS_SNAPPROCESS,
    };

    // 1. Count connections per PID (TCP + UDP).
    let mut conns: HashMap<u32, (u32, u32)> = HashMap::new(); // pid -> (tcp, udp)

    unsafe {
        // TCP
        let mut size: u32 = 0;
        GetExtendedTcpTable(
            std::ptr::null_mut(),
            &mut size,
            0,
            2, // AF_INET
            TCP_TABLE_OWNER_PID_ALL,
            0,
        );
        if size > 0 && size < 64 * 1024 * 1024 {
            let mut buf = vec![0u8; size as usize];
            let ret = GetExtendedTcpTable(
                buf.as_mut_ptr() as *mut std::ffi::c_void,
                &mut size,
                0,
                2,
                TCP_TABLE_OWNER_PID_ALL,
                0,
            );
            if ret == 0 {
                let count = *(buf.as_ptr() as *const u32) as usize;
                let rows = buf.as_ptr().add(4) as *const MIB_TCPROW_OWNER_PID;
                for i in 0..count {
                    let pid = (*rows.add(i)).dwOwningPid;
                    if pid > 4 {
                        let e = conns.entry(pid).or_insert((0, 0));
                        e.0 += 1;
                    }
                }
            }
        }

        // UDP
        let mut usize_: u32 = 0;
        GetExtendedUdpTable(
            std::ptr::null_mut(),
            &mut usize_,
            0,
            2,
            UDP_TABLE_OWNER_PID,
            0,
        );
        if usize_ > 0 && usize_ < 64 * 1024 * 1024 {
            let mut buf = vec![0u8; usize_ as usize];
            let ret = GetExtendedUdpTable(
                buf.as_mut_ptr() as *mut std::ffi::c_void,
                &mut usize_,
                0,
                2,
                UDP_TABLE_OWNER_PID,
                0,
            );
            if ret == 0 {
                let count = *(buf.as_ptr() as *const u32) as usize;
                let rows = buf.as_ptr().add(4) as *const MIB_UDPROW_OWNER_PID;
                for i in 0..count {
                    let pid = (*rows.add(i)).dwOwningPid;
                    if pid > 4 {
                        let e = conns.entry(pid).or_insert((0, 0));
                        e.1 += 1;
                    }
                }
            }
        }
    }

    // NOTE: previously we returned empty when totals were 0. That hid the
    // process list during idle seconds. Now we still return the connection
    // table (with ~0 rates) so the UI always shows which processes hold
    // sockets, even when no bytes flowed in this 1s window.
    if conns.is_empty() {
        return Vec::new();
    }
    let idle = (total_up + total_down) <= 0.0;

    // 2. Resolve PID -> process name via ToolHelp snapshot.
    let mut names: HashMap<u32, String> = HashMap::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap != -1 {
            let mut entry: PROCESSENTRY32 = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<PROCESSENTRY32>() as u32;
            if Process32First(snap, &mut entry) != 0 {
                loop {
                    let pid = entry.th32ProcessID;
                    if conns.contains_key(&pid) {
                        let raw = &entry.szExeFile;
                        let len = raw.iter().position(|&c| c == 0).unwrap_or(raw.len());
                        let name = String::from_utf8_lossy(&raw[..len]).to_string();
                        names.insert(pid, name);
                    }
                    if Process32Next(snap, &mut entry) == 0 {
                        break;
                    }
                }
            }
            windows_sys::Win32::Foundation::CloseHandle(snap);
        }
    }

    // 3. Attribute interface totals across PIDs by connection share.
    // This is an estimate (Windows has no per-PID byte counters without
    // ETW/WFP drivers) — the UI labels it as such.
    let total_conns: u32 = conns.values().map(|(t, u)| t + u).sum();
    if total_conns == 0 {
        return Vec::new();
    }

    let mut procs: Vec<ProcessTraffic> = conns
        .into_iter()
        .map(|(pid, (tcp, udp))| {
            let c = tcp + udp;
            let share = c as f64 / total_conns as f64;
            let up = total_up * share;
            let down = total_down * share;
            let proto = if tcp > 0 && udp > 0 {
                "TCP+UDP"
            } else if udp > 0 {
                "UDP"
            } else {
                "TCP"
            }
            .to_string();
            ProcessTraffic {
                pid,
                name: names.get(&pid).cloned().unwrap_or_else(|| format!("pid {pid}")),
                protocol: proto,
                up_bps: up,
                down_bps: down,
                total_bps: up + down,
                connections: c,
            }
        })
        .collect();

    // When idle there is nothing to attribute; still sort by connection
    // count so the busiest socket holders stay on top.
    if idle {
        procs.sort_by_key(|p| std::cmp::Reverse(p.connections));
    } else {
        procs.sort_by(|a, b| {
            b.total_bps
                .partial_cmp(&a.total_bps)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
    }
    procs.truncate(12);
    procs
}

// ---------------- Non-Windows fallback: /proc/net/dev ----------------
#[cfg(not(windows))]
fn read_interface_counters_fallback() -> Vec<IfCounters> {
    let content = std::fs::read_to_string("/proc/net/dev").unwrap_or_default();
    let mut out = Vec::new();
    for line in content.lines().skip(2) {
        let mut parts = line.split(':');
        let name = parts.next().unwrap_or("").trim().to_string();
        let rest = parts.next().unwrap_or("");
        let nums: Vec<u64> = rest
            .split_whitespace()
            .filter_map(|s| s.parse::<u64>().ok())
            .collect();
        if name.is_empty() || nums.len() < 10 || name == "lo" {
            continue;
        }
        out.push(IfCounters {
            alias: name.clone(),
            name: name.clone(),
            in_octets: nums[0],
            out_octets: nums[8],
            speed_bps: 0,
            is_up: true,
        });
    }
    out
}

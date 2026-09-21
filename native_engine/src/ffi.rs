use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::OnceLock;
use std::time::Duration;

use crate::bandwidth::BandwidthMonitor;
use crate::engine::{Engine, TargetConfig};
use crate::probe::{execute_probe, ProbeProtocol};
use crate::traceroute::TracerouteManager;
use crate::warp::WarpManager;

static TRACEROUTE_MANAGER: OnceLock<TracerouteManager> = OnceLock::new();

fn get_traceroute_manager() -> &'static TracerouteManager {
    TRACEROUTE_MANAGER.get_or_init(TracerouteManager::new)
}

static BANDWIDTH_MONITOR: OnceLock<BandwidthMonitor> = OnceLock::new();

fn get_bandwidth_monitor() -> &'static BandwidthMonitor {
    BANDWIDTH_MONITOR.get_or_init(BandwidthMonitor::new)
}

static WARP_MANAGER: OnceLock<WarpManager> = OnceLock::new();

fn get_warp_manager() -> &'static WarpManager {
    WARP_MANAGER.get_or_init(WarpManager::new)
}

/// Shared runtime for one-shot `quick_ping` calls. Creating a new Tokio
/// runtime per call costs milliseconds and leaks threads under load.
static QUICK_RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn get_quick_runtime() -> Option<&'static tokio::runtime::Runtime> {
    QUICK_RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("netstudio-quick-ping")
            .build()
            .expect("quick-ping runtime")
    });
    QUICK_RT.get()
}

#[no_mangle]
pub extern "C" fn netstudio_engine_new() -> *mut Engine {
    match Engine::new() {
        Ok(engine) => Box::into_raw(Box::new(engine)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Frees an engine previously returned by [`netstudio_engine_new`].
///
/// # Safety
/// `engine` must be a non-null pointer from [`netstudio_engine_new`] that
/// has not been freed before. Null pointers are ignored.
#[no_mangle]
pub unsafe extern "C" fn netstudio_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

/// Adds a probe target to the engine.
///
/// # Safety
/// `engine` must be a live pointer from [`netstudio_engine_new`]; `name`
/// and `host` must point to valid NUL-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn netstudio_add_target(
    engine: *mut Engine,
    id: u32,
    name: *const c_char,
    host: *const c_char,
    port: u16,
    protocol: u32,
    interval_ms: u64,
    timeout_ms: u64,
) -> bool {
    if engine.is_null() || name.is_null() || host.is_null() {
        return false;
    }

    let name_str = match CStr::from_ptr(name).to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return false,
    };

    let host_str = match CStr::from_ptr(host).to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return false,
    };

    if name_str.len() > 128 || host_str.is_empty() || host_str.len() > 253 || port == 0 {
        return false;
    }
    let config = TargetConfig {
        id,
        name: name_str,
        host: host_str,
        port,
        protocol: ProbeProtocol::from_u32(protocol),
        interval_ms: interval_ms.clamp(200, 60000),
        timeout_ms: timeout_ms.clamp(100, 10000),
    };

    (*engine).add_target(config);
    true
}

/// Removes a probe target (and aborts its probe loop).
///
/// # Safety
/// `engine` must be a live pointer from [`netstudio_engine_new`].
#[no_mangle]
pub unsafe extern "C" fn netstudio_remove_target(engine: *mut Engine, id: u32) -> bool {
    if engine.is_null() {
        return false;
    }
    (*engine).remove_target(id);
    true
}

/// Starts all probe loops.
///
/// # Safety
/// `engine` must be a live pointer from [`netstudio_engine_new`].
#[no_mangle]
pub unsafe extern "C" fn netstudio_start(engine: *mut Engine) -> bool {
    if engine.is_null() {
        return false;
    }
    (*engine).start();
    true
}

/// Stops all probe loops and aborts their tasks.
///
/// # Safety
/// `engine` must be a live pointer from [`netstudio_engine_new`].
#[no_mangle]
pub unsafe extern "C" fn netstudio_stop(engine: *mut Engine) -> bool {
    if engine.is_null() {
        return false;
    }
    (*engine).stop();
    true
}

/// Returns whether the engine is currently running.
///
/// # Safety
/// `engine` must be a live pointer from [`netstudio_engine_new`].
#[no_mangle]
pub unsafe extern "C" fn netstudio_is_running(engine: *mut Engine) -> bool {
    if engine.is_null() {
        return false;
    }
    (*engine).is_running()
}

/// Returns a JSON snapshot of all targets; free with [`netstudio_free_string`].
///
/// # Safety
/// `engine` must be a live pointer from [`netstudio_engine_new`]. The
/// returned pointer must be freed exactly once via [`netstudio_free_string`].
#[no_mangle]
pub unsafe extern "C" fn netstudio_get_metrics_json(engine: *mut Engine) -> *mut c_char {
    if engine.is_null() {
        return std::ptr::null_mut();
    }

    let json_str = (*engine).get_metrics_json();
    match CString::new(json_str) {
        Ok(c_string) => c_string.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Frees a string previously returned by this library.
///
/// # Safety
/// `s` must be a non-null pointer returned by this library that has not
/// been freed before. Null pointers are ignored.
#[no_mangle]
pub unsafe extern "C" fn netstudio_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// One-shot probe; returns RTT in ms or `-1.0` on failure.
///
/// # Safety
/// `host` must point to a valid NUL-terminated UTF-8 C string (or be null,
/// which yields `-1.0`).
#[no_mangle]
pub unsafe extern "C" fn netstudio_quick_ping(
    host: *const c_char,
    port: u16,
    protocol: u32,
    timeout_ms: u32,
) -> f64 {
    if host.is_null() {
        return -1.0;
    }

    let host_str = match CStr::from_ptr(host).to_str() {
        Ok(s) => s,
        Err(_) => return -1.0,
    };

    let proto = ProbeProtocol::from_u32(protocol);
    let dur = Duration::from_millis((timeout_ms as u64).clamp(100, 10000));

    let rt = match get_quick_runtime() {
        Some(r) => r,
        None => return -1.0,
    };

    let result = rt.block_on(execute_probe(proto, host_str, port, dur));
    if result.success {
        result.rtt_ms
    } else {
        -1.0
    }
}

/// Starts a traceroute session; returns a session id (`0` = failure).
///
/// # Safety
/// `host` must point to a valid NUL-terminated UTF-8 C string (or be null,
/// which yields `0`).
#[no_mangle]
pub unsafe extern "C" fn netstudio_traceroute_start(
    host: *const c_char,
    max_hops: u8,
    timeout_ms: u32,
) -> u32 {
    if host.is_null() {
        return 0;
    }

    let host_str = match CStr::from_ptr(host).to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return 0,
    };

    get_traceroute_manager().start_traceroute(host_str, max_hops, timeout_ms)
}

/// Polls traceroute progress as JSON; free with [`netstudio_free_string`].
///
/// # Safety
/// Any `u32` is accepted (unknown ids yield null); a non-null result must
/// be freed exactly once via [`netstudio_free_string`].
#[no_mangle]
pub unsafe extern "C" fn netstudio_traceroute_poll(session_id: u32) -> *mut c_char {
    if session_id == 0 {
        return std::ptr::null_mut();
    }

    if let Some(json) = get_traceroute_manager().poll_progress_json(session_id) {
        match CString::new(json) {
            Ok(c_str) => c_str.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    } else {
        std::ptr::null_mut()
    }
}

/// Requests cancellation of a traceroute session.
///
/// # Safety
/// Any `u32` is accepted (unknown ids simply return `false`).
#[no_mangle]
pub unsafe extern "C" fn netstudio_traceroute_stop(session_id: u32) -> bool {
    if session_id == 0 {
        return false;
    }

    get_traceroute_manager().stop_traceroute(session_id)
}

/// Frees a traceroute session.
///
/// # Safety
/// Any `u32` is accepted (unknown ids are ignored).
#[no_mangle]
pub unsafe extern "C" fn netstudio_traceroute_free(session_id: u32) {
    if session_id != 0 {
        get_traceroute_manager().free_session(session_id);
    }
}

#[no_mangle]
pub extern "C" fn netstudio_bandwidth_start(interval_ms: u32) -> bool {
    get_bandwidth_monitor().start(interval_ms.into());
    true
}

#[no_mangle]
pub extern "C" fn netstudio_bandwidth_stop() -> bool {
    get_bandwidth_monitor().stop();
    true
}

#[no_mangle]
pub extern "C" fn netstudio_bandwidth_poll() -> *mut c_char {
    let json = get_bandwidth_monitor().snapshot_json();
    match CString::new(json) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn netstudio_bandwidth_is_running() -> bool {
    get_bandwidth_monitor().is_running()
}

/// Starts a warp scan over an `ip:port,...` CSV; returns a session id (`0` = failure).
///
/// # Safety
/// `endpoints_csv` must point to a valid NUL-terminated UTF-8 C string
/// (or be null, which yields `0`).
#[no_mangle]
pub unsafe extern "C" fn netstudio_warp_start(
    endpoints_csv: *const c_char,
    parallel: u32,
    timeout_ms: u32,
) -> u32 {
    if endpoints_csv.is_null() {
        return 0;
    }
    let csv = match CStr::from_ptr(endpoints_csv).to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };
    // Format: "ip:port,ip:port,..." — expansion (ranges) happens in Dart.
    // Hard caps: 256KB input, 4096 endpoints max to avoid OOM.
    if csv.len() > 256 * 1024 {
        return 0;
    }
    const MAX_WARP_ENDPOINTS: usize = 4096;
    let mut endpoints: Vec<(String, u16)> = Vec::new();
    for item in csv.split(',') {
        if endpoints.len() >= MAX_WARP_ENDPOINTS {
            return 0;
        }
        let item = item.trim();
        if item.is_empty() {
            continue;
        }
        // Use last ':' so bare IPv4 works; bracketed IPv6 [::1]:443 works.
        // Bare IPv6 without brackets is rejected (ambiguous port).
        let (ip_part, port_part) = match item.rsplit_once(':') {
            Some((a, b)) => (a.trim(), b.trim()),
            None => return 0,
        };
        let ip_str = ip_part.trim_matches(|c| c == '[' || c == ']').trim();
        if ip_str.is_empty() || ip_str.contains(':') && !ip_part.starts_with('[') {
            // Likely a bare IPv6 address without port — reject.
            continue;
        }
        let port: u16 = match port_part.parse() {
            Ok(p) if p >= 1 => p,
            _ => return 0,
        };
        if ip_str.len() > 253 {
            return 0;
        }
        endpoints.push((ip_str.to_string(), port));
    }
    if endpoints.is_empty() {
        return 0;
    }
    get_warp_manager().start_scan(endpoints, parallel, timeout_ms)
}

/// Polls warp scan progress as JSON; free with [`netstudio_free_string`].
///
/// # Safety
/// Any `u32` is accepted (unknown ids yield null); a non-null result must
/// be freed exactly once via [`netstudio_free_string`].
#[no_mangle]
pub unsafe extern "C" fn netstudio_warp_poll(session_id: u32) -> *mut c_char {
    if session_id == 0 {
        return std::ptr::null_mut();
    }
    if let Some(json) = get_warp_manager().poll_progress_json(session_id) {
        match CString::new(json) {
            Ok(c_str) => c_str.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    } else {
        std::ptr::null_mut()
    }
}

/// Requests cancellation of a warp scan session.
///
/// # Safety
/// Any `u32` is accepted (unknown ids simply return `false`).
#[no_mangle]
pub unsafe extern "C" fn netstudio_warp_stop(session_id: u32) -> bool {
    if session_id == 0 {
        return false;
    }
    get_warp_manager().stop_scan(session_id)
}

/// Frees a warp scan session.
///
/// # Safety
/// Any `u32` is accepted (unknown ids are ignored).
#[no_mangle]
pub unsafe extern "C" fn netstudio_warp_free(session_id: u32) {
    if session_id != 0 {
        get_warp_manager().free_session(session_id);
    }
}

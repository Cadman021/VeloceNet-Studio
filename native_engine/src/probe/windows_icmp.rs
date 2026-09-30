#[cfg(windows)]
pub mod imp {
    use super::super::tcp::ProbeResult;
    use std::ffi::c_void;
    use std::mem::size_of;
    use std::net::{IpAddr, ToSocketAddrs};
    use std::time::Instant;
    use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        IcmpCloseHandle, IcmpCreateFile, IcmpSendEcho, IP_OPTION_INFORMATION,
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

    pub fn ping_icmp_sync(host: &str, timeout_ms: u32) -> ProbeResult {
        // Resolve host to IPv4
        let socket_addr = match format!("{}:0", host).to_socket_addrs() {
            Ok(mut iter) => match iter.find(|sa| sa.is_ipv4()) {
                Some(sa) => sa,
                None => {
                    return ProbeResult {
                        success: false,
                        rtt_ms: -1.0,
                        error: Some("No IPv4 address resolved for host".to_string()),
                    }
                }
            },
            Err(e) => {
                return ProbeResult {
                    success: false,
                    rtt_ms: -1.0,
                    error: Some(format!("DNS resolution failed: {}", e)),
                }
            }
        };

        let ipv4 = match socket_addr.ip() {
            IpAddr::V4(v4) => v4,
            _ => {
                return ProbeResult {
                    success: false,
                    rtt_ms: -1.0,
                    error: Some("Target is not IPv4".to_string()),
                }
            }
        };

        let octets = ipv4.octets();
        // IcmpSendEcho takes DestinationAddress as IPAddr (u32 in network
        // byte order: value (o1<<24)|(o2<<16)|(o3<<8)|o4).
        let dest_ip: u32 = u32::from_be_bytes(octets);

        unsafe {
            let handle: HANDLE = IcmpCreateFile();
            if handle == INVALID_HANDLE_VALUE || handle == 0 {
                return ProbeResult {
                    success: false,
                    rtt_ms: -1.0,
                    error: Some("Failed to open ICMP handle".to_string()),
                };
            }

            let send_data = b"NetStudioEchoProbePacketPayload!";
            let reply_buf_size = size_of::<IcmpEchoReply>() + send_data.len() + 8;
            let mut reply_buf = vec![0u8; reply_buf_size];

            let start = Instant::now();
            let replies_count = IcmpSendEcho(
                handle,
                dest_ip,
                send_data.as_ptr() as *const c_void,
                send_data.len() as u16,
                std::ptr::null(),
                reply_buf.as_mut_ptr() as *mut c_void,
                reply_buf_size as u32,
                timeout_ms,
            );

            let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
            IcmpCloseHandle(handle);

            if replies_count > 0 {
                let reply = &*(reply_buf.as_ptr() as *const IcmpEchoReply);
                // Note: no IP display conversion needed here (status only).
                // IP_SUCCESS is 0
                if reply.status == 0 {
                    // IcmpSendEcho reports whole milliseconds, so sub-ms
                    // LAN replies come back as 0. The wall-clock measurement
                    // is the honest value then (previously a fabricated
                    // constant 0.5 was used whenever elapsed >= 1 ms).
                    let rtt = if reply.round_trip_time == 0 {
                        elapsed_ms
                    } else {
                        reply.round_trip_time as f64
                    };
                    ProbeResult {
                        success: true,
                        rtt_ms: rtt,
                        error: None,
                    }
                } else {
                    ProbeResult {
                        success: false,
                        rtt_ms: -1.0,
                        error: Some(format!("ICMP error status: {}", reply.status)),
                    }
                }
            } else {
                ProbeResult {
                    success: false,
                    rtt_ms: -1.0,
                    error: Some("ICMP request timed out".to_string()),
                }
            }
        }
    }
}

#[cfg(not(windows))]
pub mod imp {
    use super::super::tcp::ProbeResult;

    pub fn ping_icmp_sync(_host: &str, _timeout_ms: u32) -> ProbeResult {
        // Fallback for non-Windows platforms (will use TCP probe or system ping)
        ProbeResult {
            success: false,
            rtt_ms: -1.0,
            error: Some("Native ICMP is only enabled on Windows in this build".to_string()),
        }
    }
}

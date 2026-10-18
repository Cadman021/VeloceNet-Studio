#[cfg(windows)]
pub mod imp {
    use super::super::tcp::ProbeResult;
    use std::ffi::c_void;
    use std::mem::size_of;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, ToSocketAddrs};
    use std::time::Instant;
    use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        Icmp6CreateFile, Icmp6SendEcho2, IcmpCloseHandle, IcmpCreateFile, IcmpSendEcho,
        ICMPV6_ECHO_REPLY_LH, IP_OPTION_INFORMATION,
    };
    use windows_sys::Win32::Networking::WinSock::{
        AF_INET6, IN6_ADDR, IN6_ADDR_0, SOCKADDR_IN6, SOCKADDR_IN6_0,
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

    /// Appends a port to a host for `ToSocketAddrs`, bracketing bare IPv6
    /// literals (`::1` -> `[::1]:0`). Without this the old
    /// `format!("{}:0", host)` produced an unparsable `::1:0`.
    fn with_port(host: &str, port: u16) -> String {
        if host.contains(':') && !host.starts_with('[') {
            format!("[{}]:{}", host, port)
        } else {
            format!("{}:{}", host, port)
        }
    }

    fn resolve(host: &str) -> Result<IpAddr, ProbeResult> {
        let addrs: Vec<IpAddr> = match with_port(host, 0).to_socket_addrs() {
            Ok(iter) => iter.map(|sa| sa.ip()).collect(),
            Err(e) => {
                return Err(ProbeResult::failure(format!(
                    "DNS resolution failed: {}",
                    e
                )))
            }
        };
        if addrs.is_empty() {
            return Err(ProbeResult::failure("No address resolved for host"));
        }
        // Preserve the historical IPv4 preference; fall back to IPv6 only
        // when the name has no A record (or the literal itself is v6).
        Ok(addrs
            .iter()
            .find(|ip| ip.is_ipv4())
            .copied()
            .unwrap_or(addrs[0]))
    }

    pub fn ping_icmp_sync(host: &str, timeout_ms: u32) -> ProbeResult {
        match resolve(host) {
            Ok(IpAddr::V4(ipv4)) => ping_v4(ipv4, timeout_ms),
            Ok(IpAddr::V6(ipv6)) => ping_v6(ipv6, timeout_ms),
            Err(failure) => failure,
        }
    }

    fn ping_v4(ipv4: Ipv4Addr, timeout_ms: u32) -> ProbeResult {
        // IcmpSendEcho takes DestinationAddress as IPAddr (u32 in network
        // byte order: value (o1<<24)|(o2<<16)|(o3<<8)|o4).
        let dest_ip: u32 = u32::from_be_bytes(ipv4.octets());

        unsafe {
            let handle: HANDLE = IcmpCreateFile();
            if handle == INVALID_HANDLE_VALUE || handle.is_null() {
                return ProbeResult::icmp_unavailable("Failed to open ICMP handle");
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
                // The reply buffer is byte-aligned; a plain reference would
                // be UB even though Vec allocations usually happen to align.
                let reply = std::ptr::read_unaligned(reply_buf.as_ptr() as *const IcmpEchoReply);
                // IP_SUCCESS is 0. IcmpSendEcho reports whole milliseconds,
                // so sub-ms LAN replies come back as 0; the wall-clock
                // measurement is the honest value then.
                if reply.status == 0 {
                    let rtt = if reply.round_trip_time == 0 {
                        elapsed_ms
                    } else {
                        reply.round_trip_time as f64
                    };
                    ProbeResult::success(rtt)
                } else {
                    ProbeResult::failure(format!("ICMP error status: {}", reply.status))
                }
            } else {
                ProbeResult::failure("ICMP request timed out")
            }
        }
    }

    fn sockaddr_in6(ip: Ipv6Addr) -> SOCKADDR_IN6 {
        SOCKADDR_IN6 {
            sin6_family: AF_INET6,
            sin6_port: 0,
            sin6_flowinfo: 0,
            sin6_addr: IN6_ADDR {
                u: IN6_ADDR_0 { Byte: ip.octets() },
            },
            // Hosts validated by the app cannot carry a `%zone` suffix, so
            // link-local scope ids are always 0 here.
            Anonymous: SOCKADDR_IN6_0 { sin6_scope_id: 0 },
        }
    }

    fn ping_v6(ipv6: Ipv6Addr, timeout_ms: u32) -> ProbeResult {
        let dest = sockaddr_in6(ipv6);

        unsafe {
            let handle: HANDLE = Icmp6CreateFile();
            if handle == INVALID_HANDLE_VALUE || handle.is_null() {
                // Treat like "ICMP not permitted": the engine may still probe
                // over TCP when the target has a port, instead of reporting a
                // misleading packet loss for a protocol the OS refused.
                return ProbeResult::icmp_unavailable("Failed to open ICMPv6 handle");
            }

            let send_data = b"NetStudioEchoProbePacketPayload!";
            let reply_buf_size = size_of::<ICMPV6_ECHO_REPLY_LH>() + send_data.len() + 8;
            let mut reply_buf = vec![0u8; reply_buf_size];

            let start = Instant::now();
            // No completion routine/event: the call blocks up to timeout_ms
            // and fills the reply buffer synchronously. A null source address
            // lets the OS pick the outgoing interface.
            let replies_count = Icmp6SendEcho2(
                handle,
                std::ptr::null_mut(),
                None,
                std::ptr::null(),
                std::ptr::null(),
                &dest,
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
                let reply =
                    std::ptr::read_unaligned(reply_buf.as_ptr() as *const ICMPV6_ECHO_REPLY_LH);
                if reply.Status == 0 {
                    let rtt = if reply.RoundTripTime == 0 {
                        elapsed_ms
                    } else {
                        reply.RoundTripTime as f64
                    };
                    ProbeResult::success(rtt)
                } else {
                    ProbeResult::failure(format!("ICMPv6 error status: {}", reply.Status))
                }
            } else {
                ProbeResult::failure("ICMPv6 request timed out")
            }
        }
    }
}

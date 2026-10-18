//! Unprivileged ICMP on Linux/macOS via "ping" sockets
//! (`socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`), the same mechanism system
//! `ping` uses without root:
//!
//! - Linux: needs the process gid inside `net.ipv4.ping_group_range`
//!   (widely enabled by default; the kernel rewrites the ICMP id and
//!   recomputes the checksum). TTL-expired replies are delivered on the
//!   socket **error queue** (IP_RECVERR + recvmsg(MSG_ERRQUEUE)), which is
//!   how unprivileged traceroute works since Linux 3.0.
//! - macOS: DGRAM ICMP sockets work for every user (icmp(4) man page:
//!   they can "receive time exceeded messages for traceroute"); those
//!   arrive on the normal receive queue as ICMP type 11/3 datagrams.
//!
//! When the socket cannot be opened (kernel without ping sockets, or a
//! `ping_group_range` that excludes this user and no CAP_NET_RAW), the
//! caller is told ICMP is *unavailable* — a distinct state from a genuine
//! probe failure, so the TCP fallback only kicks in where it must.

use std::io;
#[cfg(target_os = "linux")]
use std::mem::size_of;
use std::mem::MaybeUninit;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4, ToSocketAddrs};
use std::time::{Duration, Instant};

use socket2::{Domain, Protocol, SockAddr, Socket, Type};

use super::tcp::ProbeResult;

/// Marker prefix in `ProbeResult::error` when the OS refused ping sockets.
/// `execute_probe` keys its TCP fallback off this instead of "any failure".
pub const ICMP_UNAVAILABLE_MSG: &str = "ICMP datagram sockets unavailable";

const ECHO_REQUEST: u8 = 8;
const ECHO_REPLY: u8 = 0;
const DEST_UNREACHABLE: u8 = 3;
const TIME_EXCEEDED: u8 = 11;
const DEFAULT_TTL: u8 = 64;
const PAYLOAD: &[u8] = b"NetStudioEchoProbePacketPayload!";
// Out-of-band errors are polled between short normal reads so a TTL-expired
// reply never sits unread until the full timeout elapses.
const ERRQUEUE_POLL: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplyKind {
    EchoReply,
    TimeExceeded,
    Unreachable,
}

#[derive(Debug, Clone, Copy)]
pub struct Reply {
    pub from: Ipv4Addr,
    pub kind: ReplyKind,
    pub rtt_ms: f64,
}

pub enum WaitOutcome {
    Reply(Reply),
    Timeout,
}

/// One ping socket. Sequence numbers are caller-visible so late replies
/// from a previous probe can be recognized and discarded instead of being
/// misattributed (traceroute probes the same destination per TTL).
pub struct IcmpSocket {
    sock: Socket,
    next_seq: u16,
    sent_at: Instant,
}

impl IcmpSocket {
    pub fn open() -> io::Result<Self> {
        let sock = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::ICMPV4))?;
        #[cfg(target_os = "linux")]
        enable_recverr(&sock);
        Ok(Self {
            sock,
            next_seq: 1,
            sent_at: Instant::now(),
        })
    }

    /// Sends one echo request with the given TTL; returns its sequence
    /// number. Stale errors from previous probes are drained first so they
    /// can't be mistaken for this probe's reply.
    pub fn send_echo(&mut self, dest: Ipv4Addr, ttl: u8) -> io::Result<u16> {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);

        // ICMP header (type, code, checksum, id, seq) + payload. Linux ping
        // sockets recompute both id and checksum; computing them here keeps
        // macOS happy, where the message we hand in must be an ICMP
        // message of at least 8 octets.
        let mut packet = Vec::with_capacity(8 + PAYLOAD.len());
        packet.push(ECHO_REQUEST);
        packet.push(0);
        packet.extend_from_slice(&[0, 0]);
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(&seq.to_be_bytes());
        packet.extend_from_slice(PAYLOAD);
        let sum = checksum(&packet);
        packet[2..4].copy_from_slice(&sum.to_be_bytes());

        self.sock.set_ttl_v4(ttl as u32)?;
        #[cfg(target_os = "linux")]
        drain_error_queue(&self.sock);

        // Pad destination to a sockaddr_in; the port field is ignored by
        // ping sockets (kernel assigns/replaces the id).
        let addr = SockAddr::from(SocketAddrV4::new(dest, 0));
        self.sent_at = Instant::now();
        self.sock.send_to(&packet, &addr)?;
        Ok(seq)
    }

    /// Waits up to [timeout] for a reply to [seq] from anywhere (a router
    /// for TTL-expired, the destination for echo replies), discarding
    /// unrelated/stale packets.
    pub fn wait_reply(&self, dest: Ipv4Addr, seq: u16, timeout: Duration) -> WaitOutcome {
        let deadline = self.sent_at + timeout;
        // socket2 0.5 recv buffers are MaybeUninit; the bytes below `n` are
        // initialized by recv_from, which is what the slice views.
        let mut buf = [MaybeUninit::<u8>::uninit(); 1500];
        loop {
            #[cfg(target_os = "linux")]
            if let Some(reply) = self.poll_error_queue(dest, seq) {
                return WaitOutcome::Reply(reply);
            }

            let now = Instant::now();
            if now >= deadline {
                return WaitOutcome::Timeout;
            }
            // Short reads keep the Linux error queue responsive; on macOS
            // this only bounds the retry cadence.
            let remaining = (deadline - now).min(ERRQUEUE_POLL);
            self.sock.set_read_timeout(Some(remaining)).ok();

            match self.sock.recv_from(&mut buf) {
                Ok((n, from)) => {
                    let src = from.as_socket();
                    let data = unsafe { std::slice::from_raw_parts(buf.as_ptr() as *const u8, n) };
                    if let Some((ip, kind, _)) = parse_icmp(data, src, seq) {
                        // Echo replies must come from the probed host;
                        // TTL-expired/unreachable legitimately come from a
                        // router on the path.
                        if kind != ReplyKind::EchoReply || ip == dest {
                            return WaitOutcome::Reply(Reply {
                                from: ip,
                                kind,
                                rtt_ms: self.sent_at.elapsed().as_secs_f64() * 1000.0,
                            });
                        }
                    }
                }
                Err(e) if is_timeout(&e) => continue,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return WaitOutcome::Timeout,
            }
        }
    }

    #[cfg(target_os = "linux")]
    fn poll_error_queue(&self, dest: Ipv4Addr, seq: u16) -> Option<Reply> {
        loop {
            let (from, kind, packet_seq) = recv_error_queue(&self.sock)?;
            let ours = match packet_seq {
                Some(s) => s == seq,
                // Payload not parseable: single-probe-at-a-time usage makes
                // the newest queued error ours with high probability.
                None => true,
            };
            let _ = dest; // routers answer TTL-expired; dest check n/a here
            if ours {
                return Some(Reply {
                    from,
                    kind,
                    rtt_ms: self.sent_at.elapsed().as_secs_f64() * 1000.0,
                });
            }
            // Stale error from an earlier probe: keep draining.
        }
    }
}

/// Resolves a user host to one IPv4 address (v4-only, like the Windows
/// ICMP path). Blocking — callers run inside `spawn_blocking`.
fn resolve_ipv4(host: &str) -> Result<Ipv4Addr, String> {
    if let Ok(v4) = host.parse::<Ipv4Addr>() {
        return Ok(v4);
    }
    match format!("{}:0", host).to_socket_addrs() {
        Ok(iter) => match iter.map(|sa| sa.ip()).find(|ip| ip.is_ipv4()) {
            Some(IpAddr::V4(v4)) => Ok(v4),
            _ => Err("No IPv4 address resolved for host".to_string()),
        },
        Err(e) => Err(format!("DNS resolution failed: {}", e)),
    }
}

/// Single ICMP echo (matrix/MTR path). Returns a result whose
/// `icmp_unavailable` flag tells `execute_probe` that the TCP fallback is
/// allowed; genuinely failed probes stay failures.
pub fn ping_icmp_sync(host: &str, timeout_ms: u32) -> ProbeResult {
    let dest = match resolve_ipv4(host) {
        Ok(v4) => v4,
        Err(msg) => return ProbeResult::failure(msg),
    };

    let mut sock = match IcmpSocket::open() {
        Ok(s) => s,
        Err(e) => return ProbeResult::icmp_unavailable(format!("{}: {}", ICMP_UNAVAILABLE_MSG, e)),
    };

    let seq = match sock.send_echo(dest, DEFAULT_TTL) {
        Ok(s) => s,
        Err(e) => return ProbeResult::failure(format!("ICMP send failed: {}", e)),
    };

    let timeout = Duration::from_millis(timeout_ms.clamp(1, 60_000) as u64);
    match sock.wait_reply(dest, seq, timeout) {
        WaitOutcome::Reply(reply) => match reply.kind {
            ReplyKind::EchoReply => ProbeResult::success(reply.rtt_ms),
            ReplyKind::TimeExceeded => ProbeResult::failure("TTL expired before destination"),
            ReplyKind::Unreachable => {
                ProbeResult::failure(format!("Destination unreachable (via {})", reply.from))
            }
        },
        WaitOutcome::Timeout => ProbeResult::failure("ICMP request timed out"),
    }
}

fn is_timeout(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    )
}

/// Classic RFC 1071 one's-complement checksum.
pub fn checksum(data: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    let (chunks, remainder) = data.as_chunks::<2>();
    for c in chunks {
        sum += u16::from_be_bytes(*c) as u32;
    }
    if let [last] = remainder {
        sum += u16::from_be_bytes([*last, 0]) as u32;
    }
    while sum > 0xFFFF {
        sum = (sum >> 16) + (sum & 0xFFFF);
    }
    !(sum as u16)
}

/// Parses one received datagram into (source ip, reply kind, inner seq).
/// Accepts bare ICMP messages (DGRAM sockets) and IP-header-prefixed ones
/// defensively. Returns None for unrelated/stale packets (wrong seq).
fn parse_icmp(
    data: &[u8],
    src: Option<SocketAddr>,
    expected_seq: u16,
) -> Option<(Ipv4Addr, ReplyKind, Option<u16>)> {
    let mut d = data;
    // Some stacks hand raw-style datagrams including the IP header.
    if d.len() >= 20 && (d[0] >> 4) == 4 && d[9] == 1 {
        let ihl = ((d[0] & 0x0F) as usize) * 4;
        if ihl < 20 || d.len() < ihl {
            return None;
        }
        d = &d[ihl..];
    }
    if d.len() < 8 {
        return None;
    }

    let src_ip = match src {
        Some(SocketAddr::V4(v4)) => *v4.ip(),
        _ => return None,
    };

    match d[0] {
        ECHO_REPLY => {
            let seq = u16::from_be_bytes([d[6], d[7]]);
            if seq != expected_seq {
                return None;
            }
            Some((src_ip, ReplyKind::EchoReply, Some(seq)))
        }
        TIME_EXCEEDED | DEST_UNREACHABLE => {
            let kind = if d[0] == TIME_EXCEEDED {
                ReplyKind::TimeExceeded
            } else {
                ReplyKind::Unreachable
            };
            let seq = inner_echo_seq(&d[8..]);
            if let Some(s) = seq {
                if s != expected_seq {
                    return None;
                }
            }
            Some((src_ip, kind, seq))
        }
        _ => None,
    }
}

/// Sequence number of our echo request quoted inside an ICMP error
/// (quoted original = IPv4 header + at least 8 octets of the ICMP header).
fn inner_echo_seq(quoted: &[u8]) -> Option<u16> {
    if quoted.len() < 20 || (quoted[0] >> 4) != 4 {
        return None;
    }
    let ihl = ((quoted[0] & 0x0F) as usize) * 4;
    if ihl < 20 || quoted.len() < ihl + 8 || quoted[ihl] != ECHO_REQUEST {
        return None;
    }
    Some(u16::from_be_bytes([quoted[ihl + 6], quoted[ihl + 7]]))
}

#[cfg(target_os = "linux")]
fn enable_recverr(sock: &Socket) {
    use std::os::unix::io::AsRawFd;
    let one: libc::c_int = 1;
    // Best-effort: without it traceroute still gets the destination's echo
    // reply, just no intermediate-hop TTL-expired errors.
    unsafe {
        libc::setsockopt(
            sock.as_raw_fd(),
            libc::IPPROTO_IP,
            libc::IP_RECVERR,
            &one as *const _ as *const libc::c_void,
            size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

#[cfg(target_os = "linux")]
fn drain_error_queue(sock: &Socket) {
    // Bounded: a pathological sender could keep the queue busy.
    for _ in 0..32 {
        if recv_error_queue(sock).is_none() {
            break;
        }
    }
}

/// Reads one queued extended error (ip(7) IP_RECVERR). Returns
/// (offender ip, kind, inner seq when parseable).
#[cfg(target_os = "linux")]
fn recv_error_queue(sock: &Socket) -> Option<(Ipv4Addr, ReplyKind, Option<u16>)> {
    use std::os::unix::io::AsRawFd;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct SockExtendedErr {
        ee_errno: u32,
        ee_origin: u8,
        ee_type: u8,
        ee_code: u8,
        ee_pad: u8,
        ee_info: u32,
        ee_data: u32,
    }
    const SO_EE_ORIGIN_ICMP: u8 = 2;

    let fd = sock.as_raw_fd();
    let mut data = [0u8; 1500];
    let mut ctrl = [0u8; 512];
    let mut from: libc::sockaddr_in = unsafe { std::mem::zeroed() };

    let mut iov = libc::iovec {
        iov_base: data.as_mut_ptr() as *mut libc::c_void,
        iov_len: data.len(),
    };
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_name = &mut from as *mut _ as *mut libc::c_void;
    msg.msg_namelen = size_of::<libc::sockaddr_in>() as libc::socklen_t;
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl.as_mut_ptr() as *mut libc::c_void;
    msg.msg_controllen = ctrl.len() as _;

    let n = unsafe { libc::recvmsg(fd, &mut msg, libc::MSG_ERRQUEUE | libc::MSG_DONTWAIT) };
    if n < 0 {
        return None;
    }
    if msg.msg_flags & libc::MSG_CTRUNC != 0 {
        return None;
    }

    let mut cmsg = unsafe { libc::CMSG_FIRSTHDR(&msg) };
    while !cmsg.is_null() {
        let hdr = unsafe { &*cmsg };
        if hdr.cmsg_level == libc::IPPROTO_IP && hdr.cmsg_type == libc::IP_RECVERR {
            let ptr = unsafe { libc::CMSG_DATA(cmsg) };
            // Guard against malformed/truncated control messages. (CMSG_LEN
            // is an unsafe fn in current libc versions.)
            let expect_len = unsafe { libc::CMSG_LEN(size_of::<SockExtendedErr>() as u32) };
            if hdr.cmsg_len as usize >= expect_len as usize {
                let ser: SockExtendedErr =
                    unsafe { std::ptr::read_unaligned(ptr as *const SockExtendedErr) };
                if ser.ee_origin == SO_EE_ORIGIN_ICMP {
                    let kind = match ser.ee_type {
                        TIME_EXCEEDED => Some(ReplyKind::TimeExceeded),
                        DEST_UNREACHABLE => Some(ReplyKind::Unreachable),
                        _ => None,
                    };
                    if let Some(kind) = kind {
                        // SO_EE_OFFENDER lives right after the struct;
                        // prefer it over msg_name (which for errors is the
                        // original destination, not the router).
                        let offender = unsafe { ptr.add(size_of::<SockExtendedErr>()) };
                        let sa: libc::sockaddr_in = unsafe {
                            std::ptr::read_unaligned(offender as *const libc::sockaddr_in)
                        };
                        let from_ip = if sa.sin_family as i32 == libc::AF_INET {
                            Ipv4Addr::from(u32::from_be(sa.sin_addr.s_addr))
                        } else {
                            Ipv4Addr::from(u32::from_be(from.sin_addr.s_addr))
                        };
                        let seq = errqueue_seq(&data[..n.max(0) as usize]);
                        return Some((from_ip, kind, seq));
                    }
                }
            }
        }
        cmsg = unsafe { libc::CMSG_NXTHDR(&msg, cmsg) };
    }
    None
}

/// Best-effort sequence extraction from an error-queue payload, which may
/// be our original request (type 8) or the ICMP error packet (type 11/3
/// with the quoted original).
#[cfg(target_os = "linux")]
fn errqueue_seq(data: &[u8]) -> Option<u16> {
    if data.len() >= 8 && data[0] == ECHO_REQUEST {
        return Some(u16::from_be_bytes([data[6], data[7]]));
    }
    if data.len() >= 8 && (data[0] == TIME_EXCEEDED || data[0] == DEST_UNREACHABLE) {
        return inner_echo_seq(&data[8..]);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_zeroes_out_when_included() {
        // A packet whose checksum field is filled by `checksum` must sum to
        // 0xFFFF (verification property of RFC 1071).
        let mut pkt = vec![8u8, 0, 0, 0, 0x12, 0x34, 0x00, 0x2a];
        pkt.extend_from_slice(b"abcde");
        let sum = checksum(&pkt);
        pkt[2..4].copy_from_slice(&sum.to_be_bytes());
        assert_eq!(checksum(&pkt), 0);
    }

    #[test]
    fn parses_echo_reply_and_rejects_wrong_seq() {
        let mut pkt = vec![0u8, 0, 0, 0, 0, 0, 0, 7];
        pkt.resize(16, 0xAB);
        let src: SocketAddr = "192.0.2.1:0".parse().unwrap();
        let ok = parse_icmp(&pkt, Some(src), 7).unwrap();
        assert_eq!(ok.0, Ipv4Addr::new(192, 0, 2, 1));
        assert_eq!(ok.1, ReplyKind::EchoReply);
        assert!(parse_icmp(&pkt, Some(src), 8).is_none());
    }

    #[test]
    fn parses_time_exceeded_with_quoted_request() {
        // ICMP time-exceeded (type 11) quoting an IPv4 header + echo request
        // with seq 0x0102.
        let mut pkt = vec![11u8, 0, 0, 0, 0, 0, 0, 0];
        let mut inner = vec![
            0x45u8, 0, 0, 28, 0, 0, 0, 0, 64, 1, 0, 0, 192, 0, 2, 9, 198, 51, 100, 1,
        ];
        inner.extend_from_slice(&[8u8, 0, 0, 0, 0, 0, 0x01, 0x02]);
        pkt.extend_from_slice(&inner);
        let src: SocketAddr = "10.0.0.1:0".parse().unwrap();
        let (ip, kind, seq) = parse_icmp(&pkt, Some(src), 0x0102).unwrap();
        assert_eq!(ip, Ipv4Addr::new(10, 0, 0, 1));
        assert_eq!(kind, ReplyKind::TimeExceeded);
        assert_eq!(seq, Some(0x0102));
        assert!(parse_icmp(&pkt, Some(src), 0x0999).is_none());
    }

    #[test]
    fn rejects_unrelated_icmp_types() {
        let pkt = vec![5u8, 0, 0, 0, 0, 0, 0, 0]; // redirect: not ours
        let src: SocketAddr = "10.0.0.1:0".parse().unwrap();
        assert!(parse_icmp(&pkt, Some(src), 1).is_none());
    }

    /// Loopback smoke test. Skipped silently where ping sockets are not
    /// permitted (e.g. `ping_group_range` excludes the user and no
    /// CAP_NET_RAW) — the TCP fallback covers that environment.
    #[test]
    fn loopback_ping_succeeds_or_skips() {
        if IcmpSocket::open().is_err() {
            eprintln!("skipping: ping sockets unavailable in this environment");
            return;
        }
        let res = ping_icmp_sync("127.0.0.1", 1000);
        if res.icmp_unavailable {
            eprintln!("skipping: {}", res.error.unwrap_or_default());
            return;
        }
        assert!(res.success, "loopback ping failed: {:?}", res.error);
        assert!(res.rtt_ms >= 0.0);
    }
}

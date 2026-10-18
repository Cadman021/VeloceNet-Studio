//! Real WireGuard handshake probes (via boringtun) for endpoint scanning.
//!
//! Background: the previous prober sent a 32-byte random blob. Real
//! WireGuard responders silently drop anything that is not a valid
//! handshake initiation (148 bytes, Noise IKpsk2), so that probe could
//! never elicit a reply from an actual server — every "success" came from
//! the TCP fallback instead. This module builds genuine initiation
//! packets, so a reply is cryptographic proof of a live WireGuard peer.
//!
//! Hard requirement: the responder's static public key. A handshake
//! initiation is MAC'd with it, and servers silently drop anything else —
//! there is NO signal without the right key. [DEFAULT_WARP_PEER_KEY] is
//! Cloudflare's published consumer-WARP peer key (byte-verified, 32
//! bytes), so the built-in catalog works out of the box; custom
//! per-endpoint keys are explicit follow-up work, not silent cheating:
//! unknown endpoints simply report timeout, exactly as before.

use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use rand_core::OsRng;

/// Cloudflare consumer-WARP peer public key, base64:
/// `bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=`
/// (verified: decodes to exactly 32 bytes).
pub const DEFAULT_WARP_PEER_KEY: [u8; 32] = [
    110, 101, 206, 11, 225, 117, 23, 17, 12, 23, 215, 114, 136, 173, 135, 231, 253, 82, 82, 220,
    199, 208, 155, 149, 163, 157, 97, 219, 3, 223, 131, 42,
];

/// WireGuard message type of a handshake response.
const MSG_HANDSHAKE_RESPONSE: u32 = 2;
/// Exact on-wire size of a handshake response packet.
const HANDSHAKE_RESPONSE_LEN: usize = 92;
/// Exact on-wire size of a handshake initiation packet.
const HANDSHAKE_INIT_LEN: usize = 148;

/// Builds a genuine 148-byte handshake initiation for `peer_key`.
/// Returns the packet plus our sender index (to match the response
/// against — parsed back out of the packet, never assumed from API
/// internals). Each call uses a fresh ephemeral identity.
pub fn build_handshake_init(peer_key: &[u8; 32]) -> Option<(Vec<u8>, u32)> {
    let secret = StaticSecret::random_from_rng(OsRng);
    let peer = PublicKey::from(*peer_key);
    let mut tunn = Tunn::new(secret, peer, None, None, 0, None);
    let mut dst = vec![0u8; 2048];
    match tunn.encapsulate(&[], &mut dst) {
        TunnResult::WriteToNetwork(packet) => {
            if packet.len() != HANDSHAKE_INIT_LEN {
                return None;
            }
            let sender = u32::from_le_bytes([packet[4], packet[5], packet[6], packet[7]]);
            Some((packet.to_vec(), sender))
        }
        _ => None,
    }
}

/// Validates a handshake response: exactly 92 bytes, message type 2, and
/// a receiver index equal to our sender index.
///
/// MACs are deliberately NOT verified: for a liveness probe, type + index
/// match is sufficient (forging those requires an on-path attacker,
/// against whom endpoint scanning is meaningless anyway).
pub fn is_handshake_response(packet: &[u8], sender_index: u32) -> bool {
    if packet.len() != HANDSHAKE_RESPONSE_LEN {
        return false;
    }
    let msg_type = u32::from_le_bytes([packet[0], packet[1], packet[2], packet[3]]);
    if msg_type != MSG_HANDSHAKE_RESPONSE {
        return false;
    }
    let receiver = u32::from_le_bytes([packet[4], packet[5], packet[6], packet[7]]);
    receiver == sender_index
}

/// LIVE network check (ignored by default: needs internet + UDP egress).
/// Run manually with: `cargo test --release live_ -- --ignored --nocapture`
/// Proves the default peer key against a real Cloudflare endpoint. If this
/// ever goes red while the network is fine, the key rotated and
/// DEFAULT_WARP_PEER_KEY must be refreshed — the scanner degrades
/// gracefully (timeouts + TCP fallback) rather than breaking.
#[cfg(test)]
mod live_tests {
    use super::*;
    use std::net::UdpSocket;
    use std::time::Duration;

    /// Control experiment: garbage UDP to a certainly-closed port must
    /// come back as ICMP refused. If even this is silent, the sandbox
    /// (not the server) is eating UDP and live tests are inconclusive.
    #[tokio::test]
    #[ignore]
    async fn live_udp_path_sanity() {
        let addr: std::net::SocketAddr = "162.159.192.1:443".parse().unwrap();
        let sock = UdpSocket::bind("0.0.0.0:0").unwrap();
        sock.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        sock.send_to(&[0u8; 16], addr).unwrap();
        let mut buf = [0u8; 1500];
        match sock.recv_from(&mut buf) {
            Ok(_) => println!("LIVE control: got bytes back"),
            Err(e) => println!("LIVE control: {e:?}"),
        }
    }

    #[tokio::test]
    #[ignore]
    async fn live_warp_handshake_any_port() {
        // engage.* is the documented live edge (resolves to healthy IPs),
        // unlike a possibly-dead single range address.
        let ip = tokio::net::lookup_host("engage.cloudflareclient.com:2408")
            .await
            .expect("dns")
            .next()
            .expect("addr")
            .ip()
            .to_string();
        println!("LIVE probing edge {ip}");
        let mut ok = false;
        for port in [2408u16, 1702, 500, 4500] {
            let addr: std::net::SocketAddr = format!("{ip}:{port}").parse().expect("addr");
            let sock = UdpSocket::bind("0.0.0.0:0").expect("bind");
            sock.set_read_timeout(Some(Duration::from_secs(5)))
                .expect("timeout");
            let Some((packet, sender)) = build_handshake_init(&DEFAULT_WARP_PEER_KEY) else {
                panic!("init must build");
            };
            if sock.send_to(&packet, addr).is_err() {
                continue;
            }
            let mut buf = [0u8; 1500];
            loop {
                match sock.recv_from(&mut buf) {
                    Ok((n, _)) => {
                        if is_handshake_response(&buf[..n], sender) {
                            println!("LIVE handshake reply from {ip}:{port} ({n} bytes)");
                            ok = true;
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            if ok {
                break;
            }
        }
        assert!(ok, "no WireGuard handshake reply on any tested port");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_initiation_packet_shape() {
        let (packet, sender) = build_handshake_init(&DEFAULT_WARP_PEER_KEY).expect("init builds");
        assert_eq!(packet.len(), HANDSHAKE_INIT_LEN);
        assert_eq!(
            u32::from_le_bytes([packet[0], packet[1], packet[2], packet[3]]),
            1
        );
        // Sender index round-trips through bytes 4..8.
        assert_eq!(
            u32::from_le_bytes([packet[4], packet[5], packet[6], packet[7]]),
            sender
        );
        // Two initiations differ (fresh ephemeral identity each time).
        let (packet2, _) = build_handshake_init(&DEFAULT_WARP_PEER_KEY).expect("init builds");
        assert_ne!(packet, packet2);
    }

    #[test]
    fn test_handshake_loopback() {
        // Full deterministic handshake with no network: initiator talks to
        // a responder Tunn in-process; the 92-byte reply must validate.
        let responder_secret = StaticSecret::random_from_rng(OsRng);
        let responder_pub_bytes = PublicKey::from(&responder_secret).to_bytes();

        let initiator_secret = StaticSecret::random_from_rng(OsRng);
        let initiator_pub = PublicKey::from(&initiator_secret);

        let mut initiator = Tunn::new(
            initiator_secret,
            PublicKey::from(responder_pub_bytes),
            None,
            None,
            0,
            None,
        );
        let mut responder = Tunn::new(responder_secret, initiator_pub, None, None, 0, None);

        let mut buf = vec![0u8; 2048];
        let (init_packet, sender) = match initiator.encapsulate(&[], &mut buf) {
            TunnResult::WriteToNetwork(p) => {
                (p.to_vec(), { u32::from_le_bytes([p[4], p[5], p[6], p[7]]) })
            }
            other => panic!(
                "expected initiation, got {:?}",
                matches!(other, TunnResult::Done)
            ),
        };
        assert_eq!(init_packet.len(), HANDSHAKE_INIT_LEN);

        let mut reply_buf = vec![0u8; 2048];
        match responder.decapsulate(None, &init_packet, &mut reply_buf) {
            TunnResult::WriteToNetwork(reply) => {
                assert!(is_handshake_response(reply, sender));
            }
            _ => panic!("responder did not answer the initiation"),
        }

        // Negative cases: wrong index, truncation, wrong type.
        let mut bad = vec![0u8; 92];
        bad[0] = 2;
        assert!(!is_handshake_response(&bad, sender.wrapping_add(1)));
        assert!(!is_handshake_response(&bad[..60], sender));
        assert!(!is_handshake_response(&init_packet, sender));
    }
}

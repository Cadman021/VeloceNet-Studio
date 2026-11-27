//! Target state transitions, kept as a small append-only alert feed.
//!
//! The desktop app keeps a 30-day alert log on disk; headless has no
//! database, so the daemon keeps the most recent transitions in memory and
//! serves them with a sequence number. A bridge that polls with `since=`
//! therefore sees every flap instead of inferring one from two snapshots,
//! and a restart only loses what the ring buffer already evicted.
//!
//! Only the `Offline` edge is recorded: `Degraded` (one lost packet) is not
//! alert-worthy, and the hysteresis in [`crate::stats`] already turns the
//! configured `offline_after`/`recover_after` counts into that single edge.

use parking_lot::Mutex;
use serde::Serialize;
use std::collections::{HashMap, HashSet, VecDeque};

use crate::stats::{TargetStats, TargetStatus};

/// Ring size: a burst covering the whole target list plus an hour of flapping
/// fits, and the memory cost stays a fixed few tens of KB.
const CAPACITY: usize = 256;

#[derive(Debug, Clone, Serialize)]
pub struct Event {
    /// Monotonic across targets; clients resume with `?since=<last seq>`.
    pub seq: u64,
    pub at_ms: u64,
    pub target_id: u32,
    pub name: String,
    pub host: String,
    pub protocol: String,
    /// `down` when the target crossed into `Offline`, `up` when it left it.
    pub kind: &'static str,
    /// Latest probe failure at the moment of the transition.
    pub error: Option<String>,
    pub error_kind: Option<&'static str>,
    /// How long the target had been offline; `None` on `down`.
    pub outage_ms: Option<u64>,
}

/// One answer to a `?since=` query.
#[derive(Debug, Default, Serialize)]
pub struct Page {
    /// Sequence number of the newest event; pass it back as `since`.
    pub seq: u64,
    /// Events evicted before the requested cursor, so a client knows it
    /// missed transitions instead of silently resuming.
    pub dropped: u64,
    pub events: Vec<Event>,
}

#[derive(Serialize)]
struct Document<'a> {
    schema: u32,
    seq: u64,
    dropped: u64,
    events: &'a [Event],
}

impl Page {
    pub fn to_json(&self) -> String {
        let document = Document {
            schema: 1,
            seq: self.seq,
            dropped: self.dropped,
            events: &self.events,
        };
        serde_json::to_string(&document)
            .unwrap_or_else(|_| r#"{"schema":1,"seq":0,"dropped":0,"events":[]}"#.to_string())
    }
}

pub struct EventLog {
    inner: Mutex<Inner>,
}

struct Inner {
    next_seq: u64,
    events: VecDeque<Event>,
}

impl EventLog {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner {
                next_seq: 1,
                events: VecDeque::with_capacity(CAPACITY),
            }),
        }
    }

    /// Assigns the sequence number and evicts the oldest event once full.
    /// Returns the stored event so the daemon can log it without re-reading.
    pub fn push(&self, mut event: Event) -> Event {
        let mut inner = self.inner.lock();
        event.seq = inner.next_seq;
        inner.next_seq += 1;
        if inner.events.len() == CAPACITY {
            inner.events.pop_front();
        }
        let stored = event.clone();
        inner.events.push_back(event);
        stored
    }

    /// Events with `seq > since`, oldest first. `since = 0` means "everything
    /// still buffered" and is what a fresh client starts with.
    pub fn page(&self, since: u64) -> Page {
        let inner = self.inner.lock();
        let head = inner.next_seq - 1;
        let first = inner.events.front().map(|event| event.seq).unwrap_or(head);
        let dropped = if since > 0 && first > since.saturating_add(1) {
            first - since - 1
        } else {
            0
        };
        Page {
            seq: head,
            dropped,
            events: inner
                .events
                .iter()
                .filter(|event| event.seq > since)
                .cloned()
                .collect(),
        }
    }
}

impl Default for EventLog {
    fn default() -> Self {
        Self::new()
    }
}

/// Remembers the last status of every target so a transition is reported
/// exactly once, no matter how often the snapshot loop runs.
#[derive(Default)]
pub struct Tracker {
    previous: HashMap<u32, TargetStatus>,
    down_since: HashMap<u32, u64>,
}

impl Tracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Compares a fresh snapshot with the previous one and records the
    /// transitions. Returns the events it pushed so the caller can log them.
    pub fn observe(&mut self, stats: &[TargetStats], log: &EventLog, now_ms: u64) -> Vec<Event> {
        let mut seen = HashSet::with_capacity(stats.len());
        let mut emitted = Vec::new();
        for target in stats {
            seen.insert(target.id);
            let previous = self.previous.insert(target.id, target.status);
            // Muted targets are still probed and reported, but the app
            // defines them as not alert-worthy, so they stay out of the feed.
            if target.muted {
                continue;
            }
            let event = match (previous, target.status) {
                (Some(TargetStatus::Offline), status) if status != TargetStatus::Offline => {
                    let since = self.down_since.remove(&target.id).unwrap_or(now_ms);
                    Some(Event {
                        seq: 0,
                        at_ms: now_ms,
                        target_id: target.id,
                        name: target.name.clone(),
                        host: target.host.clone(),
                        protocol: target.protocol.clone(),
                        kind: "up",
                        error: target.last_error.clone(),
                        error_kind: target.last_error_kind.map(|kind| kind.as_str()),
                        outage_ms: Some(now_ms.saturating_sub(since)),
                    })
                }
                (previous, TargetStatus::Offline) if previous != Some(TargetStatus::Offline) => {
                    self.down_since.entry(target.id).or_insert(now_ms);
                    Some(Event {
                        seq: 0,
                        at_ms: now_ms,
                        target_id: target.id,
                        name: target.name.clone(),
                        host: target.host.clone(),
                        protocol: target.protocol.clone(),
                        kind: "down",
                        error: target.last_error.clone(),
                        error_kind: target.last_error_kind.map(|kind| kind.as_str()),
                        outage_ms: None,
                    })
                }
                _ => None,
            };
            if let Some(event) = event {
                emitted.push(log.push(event));
            }
        }
        // A reload can drop targets; forgetting them keeps the maps bounded
        // and lets a target that comes back start a fresh outage.
        self.previous.retain(|id, _| seen.contains(id));
        self.down_since.retain(|id, _| seen.contains(id));
        emitted
    }
}

/// Reads `since=` out of a raw query string. Absent means "everything
/// buffered"; anything that is not a number is a client bug worth a 400.
pub fn since_param(query: &str) -> Result<u64, String> {
    for pair in query.split('&') {
        let Some((name, value)) = pair.split_once('=') else {
            continue;
        };
        if name == "since" {
            return value
                .parse::<u64>()
                .map_err(|_| "since must be a non-negative integer".to_string());
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stats::ProbeErrorKind;

    /// Built by hand, not from a tracker: the hysteresis thresholds are
    /// process-wide statics that other tests mutate in parallel, so deriving
    /// a status would make these assertions order-dependent.
    fn target(id: u32, status: TargetStatus, muted: bool) -> TargetStats {
        TargetStats {
            id,
            name: format!("target-{id}"),
            host: "10.0.0.1".to_string(),
            port: 80,
            protocol: "TCP".to_string(),
            status,
            sent_count: 2,
            received_count: 2,
            lost_count: 0,
            loss_rate: 0.0,
            last_rtt_ms: 1.0,
            min_rtt_ms: 1.0,
            max_rtt_ms: 1.0,
            avg_rtt_ms: 1.0,
            jitter_ms: 0.0,
            history: Vec::new(),
            last_checked_epoch_ms: 1_000,
            last_success_epoch_ms: 1_000,
            http_status: None,
            cert_days_left: None,
            last_error: Some("timeout".to_string()),
            last_error_kind: Some(ProbeErrorKind::Timeout),
            tcp_fallback: false,
            stale: false,
            last_sample_age_ms: Some(0),
            stale_after_ms: 3_500,
            group: String::new(),
            muted,
        }
    }

    fn manual(at_ms: u64, name: &str) -> Event {
        Event {
            seq: 0,
            at_ms,
            target_id: 1,
            name: name.to_string(),
            host: "10.0.0.1".to_string(),
            protocol: "TCP".to_string(),
            kind: "down",
            error: Some("timeout".to_string()),
            error_kind: Some("timeout"),
            outage_ms: None,
        }
    }

    #[test]
    fn an_outage_is_recorded_once_and_timed() {
        let log = EventLog::new();
        let mut tracker = Tracker::new();
        assert!(tracker
            .observe(&[target(1, TargetStatus::Online, false)], &log, 1_000)
            .is_empty());

        let events = tracker.observe(&[target(1, TargetStatus::Offline, false)], &log, 4_000);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, "down");
        assert_eq!(events[0].seq, 1);
        assert_eq!(events[0].error.as_deref(), Some("timeout"));
        assert_eq!(events[0].error_kind, Some("timeout"));
        assert_eq!(events[0].outage_ms, None);

        // Staying offline must not repeat the alert.
        assert!(tracker
            .observe(&[target(1, TargetStatus::Offline, false)], &log, 9_000)
            .is_empty());

        let events = tracker.observe(&[target(1, TargetStatus::Online, false)], &log, 64_000);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, "up");
        assert_eq!(events[0].seq, 2);
        assert_eq!(events[0].outage_ms, Some(60_000));
    }

    #[test]
    fn degradation_and_pending_are_not_alert_worthy() {
        let log = EventLog::new();
        let mut tracker = Tracker::new();
        assert!(tracker
            .observe(&[target(1, TargetStatus::Pending, false)], &log, 500)
            .is_empty());
        assert!(tracker
            .observe(&[target(1, TargetStatus::Online, false)], &log, 1_000)
            .is_empty());
        // One lost packet is Degraded, not Offline.
        assert!(tracker
            .observe(&[target(1, TargetStatus::Degraded, false)], &log, 2_000)
            .is_empty());
        assert!(tracker
            .observe(&[target(1, TargetStatus::Online, false)], &log, 3_000)
            .is_empty());
        assert_eq!(log.page(0).events.len(), 0);
    }

    #[test]
    fn muted_targets_never_reach_the_feed() {
        let log = EventLog::new();
        let mut tracker = Tracker::new();
        tracker.observe(&[target(1, TargetStatus::Online, true)], &log, 1_000);
        assert!(tracker
            .observe(&[target(1, TargetStatus::Offline, true)], &log, 2_000)
            .is_empty());
        assert_eq!(log.page(0).events.len(), 0);
    }

    #[test]
    fn a_target_that_disappears_and_returns_alerts_again() {
        let log = EventLog::new();
        let mut tracker = Tracker::new();
        tracker.observe(&[target(1, TargetStatus::Online, false)], &log, 1_000);
        tracker.observe(&[target(1, TargetStatus::Offline, false)], &log, 2_000);
        // Reload removed it.
        assert!(tracker.observe(&[], &log, 3_000).is_empty());
        // It is back in the file and already offline: a new outage, not a
        // continuation of the old one.
        let events = tracker.observe(&[target(1, TargetStatus::Offline, false)], &log, 4_000);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, "down");
        assert_eq!(events[0].seq, 2);
    }

    #[test]
    fn a_new_target_that_is_already_down_alerts_on_first_sight() {
        let log = EventLog::new();
        let mut tracker = Tracker::new();
        let events = tracker.observe(&[target(7, TargetStatus::Offline, false)], &log, 1_000);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].target_id, 7);
        assert_eq!(events[0].outage_ms, None);
    }

    #[test]
    fn a_page_reports_what_the_ring_evicted() {
        let log = EventLog::new();
        for index in 0..300 {
            log.push(manual(index as u64, "target-1"));
        }
        let page = log.page(0);
        assert_eq!(page.seq, 300);
        assert_eq!(page.events.len(), CAPACITY);
        assert_eq!(page.events.first().map(|event| event.seq), Some(45));
        assert_eq!(page.dropped, 0, "a fresh client cannot miss anything");

        let resumed = log.page(1);
        assert_eq!(resumed.events.len(), CAPACITY);
        assert_eq!(resumed.dropped, 43);

        let current = log.page(300);
        assert!(current.events.is_empty());
        assert_eq!(current.dropped, 0);
    }

    #[test]
    fn the_query_parser_rejects_junk_but_defaults_to_everything() {
        assert_eq!(since_param("").expect("default"), 0);
        assert_eq!(since_param("foo=1").expect("ignored"), 0);
        assert_eq!(since_param("a=1&since=42").expect("parsed"), 42);
        assert!(since_param("since=abc").is_err());
        assert!(since_param("since=-1").is_err());
    }

    #[test]
    fn the_document_carries_its_schema_and_cursor() {
        let log = EventLog::new();
        log.push(manual(1_000, "edge"));
        let json = log.page(0).to_json();
        assert!(json.contains(r#""schema":1"#), "{json}");
        assert!(json.contains(r#""seq":1"#), "{json}");
        assert!(json.contains(r#""kind":"down""#), "{json}");
        assert!(json.contains(r#""name":"edge""#), "{json}");
    }
}

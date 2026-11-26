use parking_lot::RwLock;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, Semaphore};
use tokio::task::JoinHandle;

use crate::probe::tcp::ProbeResult;
use crate::probe::{execute_probe, ProbeProtocol};
use crate::stats::{ProbeSample, TargetMetricTracker, TargetStats};

/// Bounds sockets, DNS lookups and blocking-pool slots independently of the
/// configured target count (up to 500).
pub const DEFAULT_PROBE_CONCURRENCY: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetConfig {
    pub id: u32,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub protocol: ProbeProtocol,
    pub interval_ms: u64,
    pub timeout_ms: u64,
    /// HTTP(S) only: request path, e.g. "/health". Empty means "/".
    pub http_path: String,
    /// Optional organization label (the app's group). Empty when unset.
    /// Surfaced as a Prometheus label by the headless daemon.
    pub group: String,
    /// Muted in the app: still probed and reported, but a failure must not
    /// raise alerts (or fail a headless `--once` run).
    pub muted: bool,
}

pub struct Engine {
    targets: Arc<RwLock<HashMap<u32, TargetConfig>>>,
    trackers: Arc<RwLock<HashMap<u32, TargetMetricTracker>>>,
    is_running: Arc<AtomicBool>,
    shutdown_tx: broadcast::Sender<()>,
    active_handles: Arc<RwLock<HashMap<u32, JoinHandle<()>>>>,
    probe_semaphore: Arc<Semaphore>,
    runtime: Option<tokio::runtime::Runtime>,
}

impl Engine {
    pub fn new() -> Result<Self, String> {
        Self::with_probe_concurrency(DEFAULT_PROBE_CONCURRENCY)
    }

    /// Same engine with a bounded number of in-flight probes (1..=256).
    pub fn with_probe_concurrency(limit: usize) -> Result<Self, String> {
        let limit = limit.clamp(1, 256);
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .thread_name("netstudio-worker")
            .build()
            .map_err(|e| format!("Failed to create Tokio runtime: {}", e))?;

        let (shutdown_tx, _) = broadcast::channel(16);

        Ok(Self {
            targets: Arc::new(RwLock::new(HashMap::new())),
            trackers: Arc::new(RwLock::new(HashMap::new())),
            is_running: Arc::new(AtomicBool::new(false)),
            shutdown_tx,
            active_handles: Arc::new(RwLock::new(HashMap::new())),
            probe_semaphore: Arc::new(Semaphore::new(limit)),
            runtime: Some(rt),
        })
    }

    pub fn add_target(&self, config: TargetConfig) {
        let id = config.id;
        let tracker = TargetMetricTracker::new(
            id,
            config.name.clone(),
            config.host.clone(),
            config.port,
            config.protocol.as_str().to_string(),
        )
        .with_schedule(config.interval_ms, config.timeout_ms)
        .with_organization(config.group.clone(), config.muted);

        self.targets.write().insert(id, config.clone());
        self.trackers.write().insert(id, tracker);

        // If engine is currently running, spawn probe loop for this target immediately
        if self.is_running.load(Ordering::SeqCst) {
            if let Some(ref rt) = self.runtime {
                // Abort any stale loop for the same id (re-add case).
                if let Some(old) = self.active_handles.write().remove(&id) {
                    old.abort();
                }
                let handle = rt.spawn(Self::run_target_loop(
                    config,
                    self.trackers.clone(),
                    self.shutdown_tx.subscribe(),
                    self.probe_semaphore.clone(),
                ));
                self.active_handles.write().insert(id, handle);
            }
        }
    }

    pub fn remove_target(&self, id: u32) {
        self.targets.write().remove(&id);
        self.trackers.write().remove(&id);
        // Abort the probe loop so removed targets stop consuming sockets.
        if let Some(handle) = self.active_handles.write().remove(&id) {
            handle.abort();
        }
    }

    pub fn start(&self) {
        if self.is_running.swap(true, Ordering::SeqCst) {
            return; // Already running
        }

        let targets = self.targets.read().clone();
        if let Some(ref rt) = self.runtime {
            // Abort any orphaned loops before starting fresh.
            {
                let mut handles = self.active_handles.write();
                for (_, h) in handles.drain() {
                    h.abort();
                }
            }

            for (_, config) in targets {
                let id = config.id;
                let handle = rt.spawn(Self::run_target_loop(
                    config,
                    self.trackers.clone(),
                    self.shutdown_tx.subscribe(),
                    self.probe_semaphore.clone(),
                ));
                self.active_handles.write().insert(id, handle);
            }
        }
    }

    pub fn stop(&self) {
        if !self.is_running.swap(false, Ordering::SeqCst) {
            return; // Already stopped
        }

        let _ = self.shutdown_tx.send(());

        let mut handles = self.active_handles.write();
        for (_, handle) in handles.drain() {
            handle.abort();
        }
    }

    pub fn is_running(&self) -> bool {
        self.is_running.load(Ordering::SeqCst)
    }

    pub fn get_metrics_snapshot(&self) -> Vec<TargetStats> {
        // Write lock: snapshot() advances hysteresis state (prev_status).
        let mut trackers = self.trackers.write();
        let mut list: Vec<TargetStats> = trackers.values_mut().map(|t| t.snapshot()).collect();
        list.sort_by_key(|t| t.id);
        list
    }

    pub fn get_metrics_json(&self) -> String {
        let stats = self.get_metrics_snapshot();
        serde_json::to_string(&stats).unwrap_or_else(|_| "[]".to_string())
    }

    /// Probe every configured target exactly once and return the resulting
    /// stats. Used by the headless binary in `--once` mode; unlike
    /// [`Engine::start`] this does not schedule periodic probes.
    ///
    /// Must not be called from inside the engine runtime (it calls
    /// `block_on`). The FFI layer never calls this, so the Dart UI is
    /// unaffected.
    pub fn probe_once(&self) -> Vec<TargetStats> {
        let Some(runtime) = self.runtime.as_ref() else {
            return Vec::new();
        };
        runtime.block_on(Self::probe_once_async(
            self.targets.clone(),
            self.trackers.clone(),
            self.probe_semaphore.clone(),
        ));
        self.get_metrics_snapshot()
    }

    async fn probe_once_async(
        targets: Arc<RwLock<HashMap<u32, TargetConfig>>>,
        trackers: Arc<RwLock<HashMap<u32, TargetMetricTracker>>>,
        semaphore: Arc<Semaphore>,
    ) {
        let configs: Vec<TargetConfig> = targets.read().values().cloned().collect();
        let mut probes = tokio::task::JoinSet::new();
        for config in configs {
            // Acquire before spawning: dispatching 500 tasks must not create
            // 500 concurrent sockets/DNS lookups (or starve the blocking pool).
            let Ok(permit) = semaphore.clone().acquire_owned().await else {
                break;
            };
            let trackers = trackers.clone();
            probes.spawn(async move {
                let _permit = permit;
                let timeout = Duration::from_millis(config.timeout_ms.max(100));
                let result = execute_probe(
                    config.protocol,
                    &config.host,
                    config.port,
                    &config.http_path,
                    timeout,
                )
                .await;
                record_probe_result(&trackers, config.id, &result);
            });
        }
        while probes.join_next().await.is_some() {}
    }

    async fn run_target_loop(
        config: TargetConfig,
        trackers: Arc<RwLock<HashMap<u32, TargetMetricTracker>>>,
        mut shutdown_rx: broadcast::Receiver<()>,
        semaphore: Arc<Semaphore>,
    ) {
        let period = Duration::from_millis(config.interval_ms.max(200));
        let timeout_dur = Duration::from_millis(config.timeout_ms.max(100));

        // Initial small jitter delay so all targets do not fire at the exact same millisecond
        let initial_delay = Duration::from_millis((config.id as u64 * 70) % 500);
        tokio::time::sleep(initial_delay).await;

        // NOTE: a fixed `sleep(period)` AFTER each probe drifts the real
        // period by the probe duration (period + RTT). `interval` ticks on a
        // fixed schedule instead; `Skip` drops catch-up ticks after a slow
        // probe rather than bursting.
        // The first tick is immediate: waiting a whole period before the
        // first sample leaves headless readiness (and Prometheus `up`) empty
        // for up to a minute on configs with a slow per-target interval.
        let mut ticker = tokio::time::interval_at(tokio::time::Instant::now(), period);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        // TCP address cache: DNS on every tick wastes a lookup per probe
        // and pins round-robin names to one answer. Refresh every ~5 min
        // (300 ticks at the 1s default) so re-resolved addresses converge
        // without per-tick cost. ICMP needs no resolution at all.
        let mut cached_addrs: Option<Vec<std::net::SocketAddr>> = None;
        let mut tick_count: u32 = 0;

        loop {
            tokio::select! {
                _ = shutdown_rx.recv() => {
                    break;
                }
                _ = ticker.tick() => {
                    tick_count = tick_count.wrapping_add(1);
                    // Wait for a slot without ignoring shutdown: with 500
                    // targets and a saturated semaphore, Ctrl+C must not
                    // wait for the whole queue to drain.
                    let permit = tokio::select! {
                        _ = shutdown_rx.recv() => break,
                        permit = semaphore.clone().acquire_owned() => {
                            match permit {
                                Ok(permit) => permit,
                                Err(_) => break,
                            }
                        }
                    };
                    let res = if config.protocol == crate::probe::ProbeProtocol::Tcp {
                        if cached_addrs.is_none() || tick_count.is_multiple_of(300) {
                            cached_addrs = crate::probe::tcp::resolve_target_addrs(
                                &config.host,
                                config.port,
                                timeout_dur,
                            )
                            .await
                            .ok();
                        }
                        match &cached_addrs {
                            Some(addrs) if !addrs.is_empty() => {
                                crate::probe::tcp::probe_tcp_addrs(addrs, timeout_dur).await
                            }
                            _ => {
                                execute_probe(
                                    config.protocol,
                                    &config.host,
                                    config.port,
                                    &config.http_path,
                                    timeout_dur,
                                )
                                .await
                            }
                        }
                    } else {
                        execute_probe(
                            config.protocol,
                            &config.host,
                            config.port,
                            &config.http_path,
                            timeout_dur,
                        )
                        .await
                    };
                    drop(permit);
                    record_probe_result(&trackers, config.id, &res);
                }
            }
        }
    }
}

fn record_probe_result(
    trackers: &Arc<RwLock<HashMap<u32, TargetMetricTracker>>>,
    id: u32,
    result: &ProbeResult,
) {
    if let Some(tracker) = trackers.write().get_mut(&id) {
        tracker.record_probe(ProbeSample {
            success: result.success,
            rtt_ms: result.rtt_ms,
            http_status: result.http_status,
            cert_days_left: result.cert_days_left,
            error_kind: result.error_kind,
            error: result.error.clone(),
            tcp_fallback: result.tcp_fallback,
        });
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.stop();
        // Dropping a Tokio runtime BLOCKS until in-flight blocking tasks
        // (ICMP/DNS probes, up to ~10s) finish — unacceptable on the Dart
        // UI thread that calls freeEngine. shutdown_background() moves that
        // wait onto a helper thread and returns immediately.
        if let Some(rt) = self.runtime.take() {
            rt.shutdown_background();
        }
    }
}

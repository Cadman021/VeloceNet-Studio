use parking_lot::RwLock;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::broadcast;
use tokio::task::JoinHandle;

use crate::probe::{execute_probe, ProbeProtocol};
use crate::stats::{TargetMetricTracker, TargetStats};

#[derive(Debug, Clone)]
pub struct TargetConfig {
    pub id: u32,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub protocol: ProbeProtocol,
    pub interval_ms: u64,
    pub timeout_ms: u64,
}

pub struct Engine {
    targets: Arc<RwLock<HashMap<u32, TargetConfig>>>,
    trackers: Arc<RwLock<HashMap<u32, TargetMetricTracker>>>,
    is_running: Arc<AtomicBool>,
    shutdown_tx: broadcast::Sender<()>,
    active_handles: Arc<RwLock<HashMap<u32, JoinHandle<()>>>>,
    runtime: Option<tokio::runtime::Runtime>,
}

impl Engine {
    pub fn new() -> Result<Self, String> {
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
        );

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
        let trackers = self.trackers.read();
        let mut list: Vec<TargetStats> = trackers.values().map(|t| t.snapshot()).collect();
        list.sort_by_key(|t| t.id);
        list
    }

    pub fn get_metrics_json(&self) -> String {
        let stats = self.get_metrics_snapshot();
        serde_json::to_string(&stats).unwrap_or_else(|_| "[]".to_string())
    }

    async fn run_target_loop(
        config: TargetConfig,
        trackers: Arc<RwLock<HashMap<u32, TargetMetricTracker>>>,
        mut shutdown_rx: broadcast::Receiver<()>,
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
        let mut ticker =
            tokio::time::interval_at(tokio::time::Instant::now() + period, period);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = shutdown_rx.recv() => {
                    break;
                }
                _ = ticker.tick() => {
                    let res = execute_probe(config.protocol, &config.host, config.port, timeout_dur).await;
                    if let Some(tracker) = trackers.write().get_mut(&config.id) {
                        tracker.record_sample(res.success, res.rtt_ms);
                    }
                }
            }
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.stop();
    }
}

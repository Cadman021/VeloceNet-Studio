# Changelog

All notable changes to VeloceNet-Studio are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Nothing yet — see `main` for work toward the next release.

## [1.2.0] — 2026-09-30

### Added
- Server backup: versioned JSON export of the target list plus paste-to-import with hardened validation (bad hosts/ports skipped, ids reassigned collision-free, 500-entry cap). Import/export lives in the matrix toolbar menu.
- Community health files: `CODE_OF_CONDUCT.md` (Contributor Covenant), `SECURITY.md` (supported versions + private reporting), and a PR template wired to this repo's checklist.
- Heatmap accessibility (thanks @ayanesato, PR #8): localized LOSS badge plus screen-reader labels in all four locales, with widget/semantics tests.

### Fixed
- Windows ICMP targets no longer silently fall back to TCP on failure (mixed fake stats, doubled timeouts); the TCP fallback now runs only where native ICMP is unavailable (non-Windows).
- Warp UDP reachability detection now treats Windows `ConnectionReset` (WSAECONNRESET) like POSIX `ConnectionRefused` — the refused branch was previously dead on Windows.
- Sub-millisecond RTT reports the measured wall-clock time instead of a fabricated `0.5` constant (ping and traceroute paths).
- Removed the dead `netstudio_quick_ping` FFI (no call sites; it also owned the only `expect()` in the engine and blocked the calling thread).
- FFI resilience: release profile switched from `panic = "abort"` to `"unwind"` and every `extern "C"` entry point runs inside a `catch_unwind` guard — an engine-internal bug now degrades to an error return instead of killing (or UB-unwinding into) the host process.
- Probe scheduling no longer drifts: per-target loops tick on a fixed `tokio::time::interval` with `MissedTickBehavior::Skip` instead of `sleep(period)` after each probe.
- Dart fallback prober: overlapping 800ms ticks no longer double-count sockets and corrupt histories (reentrancy guard); offline status now needs 3 *consecutive* failures instead of 3 lifetime losses ever.
- Port scanner: `Socket.connect` timeouts surface as `SocketException`, so the old `TimeoutException` branch was dead and everything showed "closed" — timeout vs refused is now distinguished by OS error code + message; DNS resolves once per scan instead of per port.
- Warp fallback: generation counter kills the stale-loop-overwrites-new-run race; scans over the 4096 endpoint cap are refused with an error instead of firing ~22k fallback sockets; the header badge now shows the actual path in use.
- Traceroute uses the native engine on Windows only; Linux/macOS go straight to the system `traceroute` binary (native bindings exist there but can only emit timeouts).
- Traceroute output decodes leniently (`allowMalformed` + stream `onError`) so non-UTF8 console codepages (e.g. cp866/cp936) can't crash the app via an unhandled `FormatException`.
- Sidebar footer is capability-honest on non-Windows ("TCP mode").
- DLL loader: cwd-anchored dev paths are now debug-only (`kDebugMode`); release builds load exclusively from the executable directory, matching the documented policy.
- Add-Server dialog validates hosts with the same normalizer the engines use (URLs normalize, bad hosts fail in the form) and uses millisecond ids so same-second double adds can't collide.
- DNS hardening: family-matched socket bind (custom IPv6 servers work), source-address check against spoofed replies, and automatic TCP retry on truncated (TC) responses per RFC 1035 §4.2.2.
- CSV hardening: formula-injection neutralization (leading `=+-@` cells are text-marked) and empty timestamps for never-checked targets instead of 1970.
- Metrics decode moved from per-tick `compute()` spawns to one persistent worker isolate (with inline fallback), killing 500ms spawn overhead and GC churn.
- Sparkline and bandwidth chart repaint only when the visible shape can differ instead of every frame.
- Target status now follows windowed loss over the recent 40-sample ring (a host down for 10 minutes recovers promptly after reconnecting) while lifetime counters stay intact for totals.
- Native traceroute probes each TTL 3× and averages successful samples, matching the system `tracert` behavior instead of letting one slow router define the hop.
- Non-Windows lints fixed (`c_void`/`size_of` imports gated to Windows, unused `host` renamed in the ICMP stub) and CI gained an Ubuntu clippy+test job so the `#[cfg(not(windows))]` paths can never rot silently again.
- Warp scans now publish live progress (tested/succeeded/failed counts plus incremental results) instead of staying at 0% until completion.
- Warp endpoints resolve via explicit IP parsing with family-matched socket binding — IPv6 targets (e.g. `[::1]:443`) actually work now instead of timing out; bare unbracketed IPv6 stays rejected (port ambiguity).

### Added
- DNS Lookup tab: raw UDP client for A/AAAA/MX/TXT/NS/CNAME/SOA records against Cloudflare/Google/Quad9 or a custom server IP, with NXDOMAIN distinction, query-time display and zone-copy. Fully localized (en/fa/ru/zh) and theme-aware.

## [1.1.0] — 2026-09-24

### Added
- JSON dictionaries: one file per language in `assets/lang/` (`en`, `fa`, `ru`, `zh`), loaded at startup with English fallback; `test/i18n_parity_test.dart` enforces identical key sets.
- Russian and Chinese UI (locale switch in Settings, persisted; Persian stays the only RTL locale).
- Release workflow now ships Windows x64 (zip), Linux x64 (tarball) and macOS arm64 (zipped `.app`, Gatekeeper note in README).
- Port Scanner tab: TCP sweep with `host` + `ports` spec (`80,443,8000-8010`, max 4096 ports), bounded-concurrency batches, open/closed/filtered states with well-known service guesses, copy-open and clear actions. Fully localized and theme-aware.
- Alert log: status transitions recorded with severity (critical/warning/info), unread badge on the matrix bell (red when the latest is critical), newest-first dialog with per-event RTT/loss detail and clear-all. Boot baselines (`pending` → anything) are not logged.
- Unit tests for traceroute host validation, metrics-snapshot decoding, the alert log and CSV export.
- CSV export: one-click snapshot of all target metrics (RFC 4180 quoting, sorted by id) to `Documents/VeloceNet-Studio/velocenet-metrics-<timestamp>.csv`, with copy-path feedback. The button shows a spinner and ignores taps while exporting (no duplicate downloads), then confirms with file name + size.

### Fixed
- Traceroute fallback races: stale stdout/exit-code/DNS callbacks from a killed run can no longer overwrite the new trace (generation counter + subscription cancel in `stop()`).
- Traceroute host validation: IPv4 (octet-checked), IPv6 (±brackets) and hostnames accepted; shell metacharacters and empty hosts rejected with an error instead of a silent no-op.
- Traceroute parser: IPv6 hop addresses recognized; RTT now averages all samples per line (was first-sample only, decimals truncated on Linux).
- Traceroute `maxHops`/`timeoutMs` clamped in Dart before FFI (unclamped `maxHops` truncated to `u8`) and before system-prober arguments.
- Metrics snapshot JSON now decodes in a background isolate (`compute`) with backpressure (overlapping ticks skipped); malformed payloads keep the previous frame.

### Changed
- Bandwidth interface counters migrated from `GetIfTable` (32-bit, wraps every ~4 GiB) to `GetIfTable2` (64-bit `InOctets`/`OutOctets`, real `TransmitLinkSpeed`, UTF-16 friendly names). Requires the `Win32_NetworkManagement_Ndis` windows-sys feature.

## [1.0.0] — 2026-09-21

First public release.

### Added
- Ping Matrix with ICMP (Windows IP Helper, no admin needed) + TCP-handshake probes, live sparklines, RTT avg/min/max, RFC 3550 jitter, loss %.
- Traceroute (TTL-based visual hop chain + data table, Windows native ICMP).
- Bandwidth monitor (per-interface live deltas via `GetIfTable`, top processes by connection share, explicitly labeled *estimated*).
- Warp Scanner (WireGuard-style UDP probe + TCP fallback, ranking, copy-to-clipboard, one-click add to Ping Matrix).
- Settings page: Light / Dark / System theme + English / فارسی locale, persisted with `shared_preferences` (default: English).
- Full i18n + theming migration for Ping Matrix, Traceroute, Bandwidth, Warp Scanner and sidebar (`AppStrings`, `ThemeX` adaptive colors).
- GitHub community files: issue templates, CI + Windows release workflows, `CONTRIBUTING.md`, expanded `README.md`.
- `LICENSE` (GPL-3.0-or-later) and repository metadata (`repository`, `homepage`, `issue_tracker`).

### Fixed
- Secure native-library loading (executable-anchored absolute paths only, no cwd/`PATH` probing → no DLL hijacking).
- FFI input validation (host/port/protocol/interval/timeout) on the Dart side, clamped ranges in the Rust engine.
- Native engine task leaks: per-target `JoinHandle` tracking, abort on `remove_target` / `start` / `stop`.
- `quick_ping` reuses a shared Tokio runtime instead of creating one per call.
- Warp CSV hardening: 256 KB / 4096-endpoint caps, bracketed-IPv6 parsing, rejection of bare IPv6 without port.
- Sidebar overflow crashes in narrow windows (flexible brand + engine-status rows).
- `AddTargetDialog` preset-name truncation (`split(' ')[0]` removed) and missing port/interval validators.
- `IndexedStack` tab navigation preserves Traceroute/Bandwidth/Warp state across tab switches.
- Native metrics polling interval 200 ms → 500 ms (less UI-thread JSON pressure); `print` → `debugPrint` in the engine service.
- Rank medals (🥇🥈🥉) replaced with text ranks (`#1`, `#2`, …) for font/i18n safety.

[Unreleased]: https://github.com/Cadman021/VeloceNet-Studio/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.2.0
[1.1.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.1.0
[1.0.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.0.0

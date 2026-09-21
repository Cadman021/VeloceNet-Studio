# Changelog

All notable changes to VeloceNet-Studio are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Nothing yet — see `main` for work toward the next release.

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

[Unreleased]: https://github.com/Cadman021/VeloceNet-Studio/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.0.0

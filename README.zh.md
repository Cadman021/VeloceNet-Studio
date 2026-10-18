# VeloceNet-Studio

[![CI](https://github.com/Cadman021/VeloceNet-Studio/actions/workflows/ci.yml/badge.svg)](https://github.com/Cadman021/VeloceNet-Studio/actions/workflows/ci.yml)
[![Release v1.5.0](https://img.shields.io/badge/release-v1.5.0-green.svg)](https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.5.0)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)]()
[![Flutter](https://img.shields.io/badge/Flutter-%E2%89%A53.22-02569B.svg)]()
[![Rust](https://img.shields.io/badge/Rust-stable-orange.svg)]()

跨平台**网络监控分析工作台**，基于 **Flutter** + **Rust 引擎 (Tokio, 经由 FFI)** 构建。

实时延迟矩阵 (ICMP / TCP)、可视化路由追踪、带宽监控、Warp 端点扫描器、TCP 端口扫描器和 DNS 查询 — 支持浅色/深色/跟随系统主题，以及英语/波斯语/俄语/中文界面。

> 许可证: **GPL-3.0-or-later** — 见 [LICENSE](LICENSE)。
>
> Read this in: [English](README.md) · [فارسی](README.fa.md) · [Русский](README.ru.md).

## 截图

> 截图位于 [`docs/screenshots/`](docs/screenshots/)。如果某张缺失，请用 <kbd>Win</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> 以 1600×900 截取并保存到对应路径。

| Ping 矩阵 (深色) | Ping 矩阵 (浅色) |
|---|---|
| ![Ping 矩阵深色](docs/screenshots/01-ping-matrix-dark.png) | ![Ping 矩阵浅色](docs/screenshots/02-ping-matrix-light.png) |

| 路由追踪 | 带宽 |
|---|---|
| ![路由追踪](docs/screenshots/03-traceroute.png) | ![带宽](docs/screenshots/04-bandwidth.png) |

| Warp 扫描器 | 设置 |
|---|---|
| ![Warp 扫描器](docs/screenshots/05-warp.png) | ![设置](docs/screenshots/06-settings.png) |

| 端口扫描器 | 告警日志 |
|---|---|
| ![端口扫描器](docs/screenshots/07-portscan.png) | ![告警日志](docs/screenshots/08-alerts.png) |

| DNS 查询 | 在线历史 |
|---|---|
| ![DNS 查询](docs/screenshots/09-dns.png) | ![在线历史](docs/screenshots/10-uptime-history.png) |

| MTR |
|---|
| ![MTR](docs/screenshots/11-mtr.png) |

## 功能

- **Ping 矩阵** — 并发 ICMP (经由 Windows IP Helper，无需管理员权限) + TCP 握手探测、实时火花线、RTT 平均/最小/最大、RFC 3550 抖动、丢包率、状态变化**告警日志** (未读角标)、一键 **CSV 导出**、版本化 **JSON 备份** (导出 + 粘贴导入)，以及每个目标的 **24 小时在线历史**与中断报告。
- **路由追踪** — 基于 TTL 的可视化跳数链 + 数据表 (Windows 原生 ICMP)、IPv4/IPv6 解析、多样本 RTT 平均。
- **MTR** — 追踪一次，然后在隔离的引擎实例上持续 ping 每个有响应的跳 (每跳 loss/avg/best/worst)。
- **带宽** — 经由 `GetIfTable2` 的各网卡实时增量 (64 位计数器)，按连接占比列出最耗流量的进程 (明确标注为*估算*)。
- **Warp 扫描器** — WireGuard 风格 UDP 探测 + TCP 回退、排名、一键复制、一键添加到 Ping 矩阵。
- **端口扫描器** — 按端口列表扫描 (`80,443,8000-8010`)，开放/关闭/已过滤三种状态、服务推测。
- **DNS 查询** — 原始 UDP 客户端，支持 A/AAAA/MX/TXT/NS/CNAME/SOA，可使用 Cloudflare/Google/Quad9 或自定义服务器，区分 NXDOMAIN 并显示查询耗时。
- **设置** — 浅色 / 深色 / 跟随系统主题 + 英语 / 波斯语 / 俄语 / 中文语言，通过 `shared_preferences` 持久化 (默认英语)，以及带测试按钮的 Telegram/Discord 告警 Webhook。
- **系统托盘** — 关闭窗口时最小化到托盘，监控继续运行；显示/隐藏/退出菜单，可在设置中关闭。
- **更新检查** — 每日轮询 GitHub Releases，启动时弹窗提示 (下载/稍后，每个版本仅一次)，设置中可手动检查。
- **弹性引擎** — 如果 Rust 的 `.dll`/`.so` 尚未构建，程序会自动使用 Dart 备用探测器，保证界面始终可用。

## 下载 (v1.5.0)

无需构建 — 从
[v1.5.0 发布页](https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.5.0)选择你的平台：

| 平台 | 文件 | 运行 |
|---|---|---|
| Windows x64 | `velocenet-studio-windows-x64.zip` | 解压并运行其中的 `.exe` (DLL 已随附在旁) |
| Linux x64 | `velocenet-studio-linux-x64.tar.gz` | 解压并运行其中的 `netstudio` 二进制文件 (`.so` 已随附在旁) |
| macOS arm64 | `velocenet-studio-macos-arm64.zip` | 解压，右键点击 `.app` → 打开 (未签名构建，需一次性 Gatekeeper 确认) |

原生 ICMP 探测目前仅支持 Windows；在 Linux/macOS 上这些探测会自动回退到 TCP。本版本内容见 [CHANGELOG.md](CHANGELOG.md)。

## 从源码构建 (Windows)

前置要求：Flutter SDK ≥ 3.22 · 稳定版 Rust (`rustup`) · Windows 10/11 x64 (完整原生功能)。

```powershell
.\build_native.ps1      # cargo build --release + stage netstudio_engine.dll
flutter pub get
flutter run -d windows
```

手动方式：

```powershell
cd native_engine
cargo build --release
Copy-Item target\release\netstudio_engine.dll ..
cd ..
flutter run -d windows
```

Linux/macOS: `cargo build --release` 会生成 `libnetstudio_engine.so` / `.dylib`；在没有 raw socket 的地方，ICMP 会回退到 TCP。

## 工作原理

```
┌──────────── Flutter UI ────────────┐      ┌────────── Rust engine ──────────┐
│ Ping Matrix · Traceroute · MTR     │ JSON │ Tokio probers (ICMP/TCP/TTL)    │
│ Bandwidth · Warp · Portscan · DNS  │◄────►│ stats (RTT/jitter/loss)         │
│ SettingsController (theme+locale)  │  FFI │ traceroute / bandwidth / warp   │
└────────────────────────────────────┘      └─────────────────────────────────┘
```

- FFI 边界：`lib/core/ffi/` (Dart) ↔ `native_engine/src/ffi.rs` (C ABI)。所有字符串在跨越边界前都在 Dart 侧校验；数值范围在两侧钳制。
- 原生库只从**运行文件所在目录锚定的绝对路径**加载 — 绝不走 cwd/`PATH` (防 DLL 劫持)。
- 状态：`PingMatrixController`、`TracerouteController`、`BandwidthController`、`WarpController`、`SettingsController` (全部基于 `ChangeNotifier`)。

## 项目结构

```
lib/
  main.dart                      # 异步启动 + SettingsController 加载
  core/ffi/                      # native_library.dart, native_bindings.dart
  core/theme/                    # app_colors.dart, app_theme.dart, theme_x.dart
  core/settings/                 # settings_controller.dart (主题+语言)
  core/i18n/                     # 基于 JSON 的 AppStrings (en/fa/ru/zh，默认 en)
  models/ services/ state/       # 包括 alert_log.dart (状态变化历史)
  views/
    main_shell_view.dart         # 侧边栏 + IndexedStack 标签页
    ping_matrix/ traceroute/ bandwidth/ warp/ portscan/ dnslookup/ settings/
native_engine/src/
  engine.rs ffi.rs stats.rs probe/ traceroute.rs bandwidth.rs warp.rs
.github/workflows/              # ci.yml, release.yml
docs/screenshots/               # 上文用到的图片
```

## 安全说明

- 不从 cwd/`PATH` 探测 DLL；缺少引擎 → Dart 备用探测器 (永不崩溃)。
- Warp 扫描输入有上限 (256 KB / 4096 个端点)；IPv6 显式处理 (方括号形式 `[::1]:port`)。
- 各进程带宽是**按连接占比估算**的 (没有 ETW 的 Windows 不提供 per-PID 字节计数器) — 界面中已如实标注。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。速览：

```bash
flutter analyze --no-pub
flutter test --no-pub
cd native_engine && cargo test --release && cargo clippy --release -- -D warnings
```

新增界面字符串必须走 `assets/lang/` 下的 JSON 词典 (四个语言 — `test/i18n_parity_test.dart` 会强制检查)；新增颜色走 `ThemeX`。Bug 与功能请求请使用 issue 模板。

## 更新日志与路线图

见 [CHANGELOG.md](CHANGELOG.md)。近期想法：Linux/macOS 原生 ICMP、Prometheus 导出端点、真实的 per-process 统计 (ETW)、桌面告警通知。

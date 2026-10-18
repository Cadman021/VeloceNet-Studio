# VeloceNet-Studio

[![CI](https://github.com/Cadman021/VeloceNet-Studio/actions/workflows/ci.yml/badge.svg)](https://github.com/Cadman021/VeloceNet-Studio/actions/workflows/ci.yml)
[![Release v1.5.0](https://img.shields.io/badge/release-v1.5.0-green.svg)](https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.5.0)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64%20%7C%20Linux%20%7C%20macOS-lightgrey.svg)]()
[![Flutter](https://img.shields.io/badge/Flutter-%E2%89%A53.22-02569B.svg)]()
[![Rust](https://img.shields.io/badge/Rust-stable-orange.svg)]()

استودیوی کراس‌پلتفرم **مانیتورینگ و تحلیل شبکه** ساخته‌شده با **Flutter** + **موتور Rust (توکیو، از طریق FFI)**.

ماتریس زنده تاخیر (ICMP / TCP / HTTP(S) با TTFB)، تریس‌روت تصویری، مانیتور پهنای باند، اسکنر اندپوینت Warp، اسکنر پورت TCP و جست‌وجوی DNS — با تم‌های روشن/تیره/سیستمی و رابط کاربری انگلیسی/فارسی/روسی/چینی.

> لایسنس: **GPL-3.0-or-later** — فایل [LICENSE](LICENSE) را ببینید.
>
> Read this in: [English](README.md) · [Русский](README.ru.md) · [中文](README.zh.md).

## تصاویر

> تصاویر در [`docs/screenshots/`](docs/screenshots/) قرار دارند. اگر تصویری نیست، با <kbd>Win</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> در ابعاد 1600×900 بگیرید و با همان مسیر ذخیره کنید.

| ماتریس پینگ (تیره) | ماتریس پینگ (روشن) |
|---|---|
| ![ماتریس پینگ تیره](docs/screenshots/01-ping-matrix-dark.png) | ![ماتریس پینگ روشن](docs/screenshots/02-ping-matrix-light.png) |

| تریس‌روت | پهنای باند |
|---|---|
| ![تریس‌روت](docs/screenshots/03-traceroute.png) | ![پهنای باند](docs/screenshots/04-bandwidth.png) |

| اسکنر Warp | تنظیمات |
|---|---|
| ![اسکنر Warp](docs/screenshots/05-warp.png) | ![تنظیمات](docs/screenshots/06-settings.png) |

| اسکنر پورت | لاگ هشدار |
|---|---|
| ![اسکنر پورت](docs/screenshots/07-portscan.png) | ![لاگ هشدار](docs/screenshots/08-alerts.png) |

| جست‌وجوی DNS | تاریخچه آپتایم |
|---|---|
| ![جست‌وجوی DNS](docs/screenshots/09-dns.png) | ![تاریخچه آپتایم](docs/screenshots/10-uptime-history.png) |

| MTR |
|---|
| ![MTR](docs/screenshots/11-mtr.png) |

## ویژگی‌ها

- **ماتریس پینگ** — پروب‌های همزمان ICMP (IP Helper در ویندوز؛ سوکت ping بدون root در لینوکس/مک) + دست‌تکانی TCP + پروب‌های HTTP(S) (TTFB، کد وضعیت، انقضای گواهی TLS)، اسپارک‌لاین زنده، RTT میانگین/کمینه/بیشینه، جیتر استاندارد RFC 3550، درصد loss، **لاگ هشدار** تغییر وضعیت با بج خوانده‌نشده، **خروجی CSV** تک‌کلیکی، **بکاپ JSON** نسخه‌دار (اکسپورت + ایمپورت با چسباندن)، **تاریخچه آپتایم ۲۴ ساعته** هر تارگت با گزارش قطعی، و **گروه/برچسب** با فیلتر یک‌کلیکی.
- **تریس‌روت** — زنجیره تصویری هاپ با TTL + جدول داده (ICMP بومی در ویندوز شامل IPv6، لینوکس و مک)، نام‌های reverse DNS هر هاپ، میانگین چندنمونه‌ای RTT، توقف زودهنگام هنگام Destination Unreachable.
- **MTR** — یک بار trace، بعد پینگ مداوم تک‌تک هاپ‌های پاسخ‌گو (loss/avg/best/worst هر هاپ) روی نمونه جدا و ایزوله انجین.
- **پهنای باند** — دلتای زنده هر اینترفیس با `GetIfTable2` (کانترهای ۶۴ بیتی)، پرمصرف‌ترین پروسه‌ها بر اساس سهم کانکشن (صراحتاً *تخمینی* اعلام شده).
- **اسکنر Warp** — پروب UDP شبه-WireGuard + فالبک TCP، رتبه‌بندی، کپی در کلیپ‌بورد، افزودن تک‌کلیکی به ماتریس پینگ.
- **اسکنر پورت** — سوییپ TCP با مشخصات لیست پورت (`80,443,8000-8010`)، وضعیت‌های باز/بسته/فیلترشده، حدس سرویس.
- **جست‌وجوی DNS** — کلاینت خام UDP برای رکوردهای A/AAAA/MX/TXT/NS/CNAME/SOA روی Cloudflare/Google/Quad9 یا سرور سفارشی، با تفکیک NXDOMAIN و نمایش زمان پرس‌وجو.
- **تنظیمات** — تم روشن / تیره / سیستمی + زبان انگلیسی / فارسی / روسی / چینی، ذخیره‌شده با `shared_preferences` (پیش‌فرض: انگلیسی)، به‌علاوه وب‌هوک‌های هشدار تلگرام/دیسکورد با دکمه تست.
- **سینی سیستم** — بستن پنجره را به کمینه‌شدن در tray می‌برد و مانیتورینگ ادامه پیدا می‌کند؛ منوی نمایش/پنهان/خروج، قابل خاموش‌کردن در تنظیمات.
- **بررسی به‌روزرسانی** — نظرسنجی روزانه ریلیزهای گیت‌هاب با دیالوگ شروع (دانلود/بعداً، برای هر نسخه فقط یک بار) و بررسی دستی در تنظیمات.
- **انجین تاب‌آور** — اگر `.dll`/`.so` راست بیلد نشده باشد، برنامه خودکار با پروبر پشتیبان Dart کار می‌کند تا رابط کاربری همیشه قابل استفاده بماند.

## دانلود (v1.5.0)

بدون نیاز به بیلد — پلتفرم خود را از
[ریلیز v1.5.0](https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v1.5.0) بگیرید:

| پلتفرم | فایل | اجرا |
|---|---|---|
| Windows x64 | `velocenet-studio-windows-x64.zip` | اکسترکت کنید و `.exe` را اجرا کنید (DLL کنارش باندل شده) |
| Linux x64 | `velocenet-studio-linux-x64.tar.gz` | اکسترکت کنید و باینری `netstudio` را اجرا کنید (`.so` کنارش باندل شده) |
| macOS arm64 | `velocenet-studio-macos-arm64.zip` | اکسترکت کنید، روی `.app` راست‌کلیک → Open (بیلد امضانشده، یک بار تأیید Gatekeeper) |

پروب بومی ICMP روی ویندوز (IP Helper) و روی لینوکس/مک (سوکت ping بدون root) اجرا می‌شود؛ فقط جایی که سیستم‌عامل آن را رد کند، شفاف به TCP برمی‌گردد. برای جزئیات این نسخه [CHANGELOG.md](CHANGELOG.md) را ببینید.

## بیلد از سورس (ویندوز)

پیش‌نیازها: Flutter SDK نسخه ۳.۲۲ به بالا · راست پایدار (`rustup`) · ویندوز ۱۰/۱۱ نسخه ۶۴ بیتی برای امکانات کامل بومی.

```powershell
.\build_native.ps1      # cargo build --release + stage netstudio_engine.dll
flutter pub get
flutter run -d windows
```

راه دستی:

```powershell
cd native_engine
cargo build --release
Copy-Item target\release\netstudio_engine.dll ..
cd ..
flutter run -d windows
```

لینوکس/مک: `cargo build --release` فایل `libnetstudio_engine.so` / `.dylib` را می‌سازد؛ ICMP از سوکت ping بدون root استفاده می‌کند و فقط در صورت رد شدن توسط سیستم‌عامل به TCP برمی‌گردد.

## چطور کار می‌کند

```
┌──────────── Flutter UI ────────────┐      ┌────────── Rust engine ──────────┐
│ Ping Matrix · Traceroute · MTR     │ JSON │ Tokio probers (ICMP/TCP/TLS)    │
│ Bandwidth · Warp · Portscan · DNS  │◄────►│ stats (RTT/jitter/loss)         │
│ SettingsController (theme+locale)  │  FFI │ traceroute / bandwidth / warp   │
└────────────────────────────────────┘      └─────────────────────────────────┘
```

- مرز FFI: `lib/core/ffi/` (دارت) ↔ `native_engine/src/ffi.rs` (رابط C). همه رشته‌ها قبل از عبور در سمت دارت اعتبارسنجی می‌شوند؛ بازه‌های عددی در هر دو سمت clamp می‌شوند.
- کتابخانه بومی فقط از **مسیرهای مطلق لنگرگرفته به پوشه فایل اجرایی** لود می‌شود — هرگز cwd/`PATH` (امن در برابر DLL-hijacking).
- استیت: `PingMatrixController`، `TracerouteController`، `BandwidthController`، `WarpController`، `SettingsController` (همه بر پایه `ChangeNotifier`).

## ساختار پروژه

```
lib/
  main.dart                      # بوت ناهمگام + لود SettingsController
  core/ffi/                      # native_library.dart, native_bindings.dart
  core/theme/                    # app_colors.dart, app_theme.dart, theme_x.dart
  core/settings/                 # settings_controller.dart (تم+زبان)
  core/i18n/                     # ‏AppStrings با پشتوانه JSON ‏(en/fa/ru/zh، پیش‌فرض en)
  models/ services/ state/       # از جمله alert_log.dart (تاریخچه تغییر وضعیت)
  views/
    main_shell_view.dart         # سایدبار + تب‌های IndexedStack
    ping_matrix/ traceroute/ bandwidth/ warp/ portscan/ dnslookup/ settings/
native_engine/src/
  engine.rs ffi.rs stats.rs probe/ traceroute.rs bandwidth.rs warp.rs
.github/workflows/              # ci.yml, release.yml
docs/screenshots/               # تصاویر استفاده‌شده بالا
```

## نکات امنیتی

- بدون جست‌وجوی DLL در cwd/`PATH`؛ نبودن انجین ← پروبر پشتیبان دارت (هیچ‌وقت کرش).
- ورودی اسکن Warp سقف دارد (۲۵۶ کیلوبایت / ۴۰۹۶ اندپوینت)؛ IPv6 صراحتاً مدیریت می‌شود (براکت‌دار `[::1]:port`).
- سهم پهنای باند هر پروسه یک **تخمین بر اساس سهم کانکشن** است (ویندوز بدون ETW کانتر بایت per-PID نمی‌دهد) — رابط کاربری همین را اعلام می‌کند.

## مشارکت

فایل [CONTRIBUTING.md](CONTRIBUTING.md) را ببینید. خلاصه:

```bash
flutter analyze --no-pub
flutter test --no-pub
cd native_engine && cargo test --release && cargo clippy --release -- -D warnings
```

رشته‌های جدید رابط کاربری باید از دیکشنری‌های JSON در `assets/lang/` بگذرند (هر چهار زبان — تست `test/i18n_parity_test.dart` اجبارش می‌کند)؛ رنگ‌های جدید از `ThemeX`. گزارش باگ و درخواست فیچر با تمپلیت‌های ایشو.

## تغییرات و نقشه راه

فایل [CHANGELOG.md](CHANGELOG.md) را ببینید. ایده‌های نزدیک: اندپوینت اکسپورت Prometheus، حسابداری واقعی per-process (ETW)، نوتیفیکیشن دسکتاپ برای هشدارها.

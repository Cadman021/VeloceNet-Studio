# Security Policy

## Supported Versions

Only the latest minor release line receives security fixes:

| Version | Supported          |
| ------- | ------------------ |
| 1.4.x   | :white_check_mark: |
| < 1.4   | :x:                |

If you are stuck on an older release, the fix will land on `main` — please
upgrade to the latest release to receive it.

## Reporting a Vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability** and describe the issue, ideally with:
   - affected version(s) / commit,
   - steps to reproduce or a proof of concept,
   - your assessment of impact (what can an attacker achieve?).

If private reporting is not enabled, contact the maintainer via their GitHub
profile at <https://github.com/Cadman021> instead of filing a public issue.

## What to Expect

- Acknowledgement of your report as soon as reasonably possible.
- Coordinated disclosure: we will work on a fix and agree on a publication
  timeline with you before any public details.
- Credit in the release notes / `CHANGELOG.md` if you wish.

## Credential Storage Disclosure

The app stores three webhook secrets (Telegram bot token, Telegram chat ID,
Discord webhook URL) so alerts keep working across restarts:

- **Windows:** DPAPI-protected (current-user scope) via direct `crypt32`
  calls — no plaintext on disk. This is the same primitive Credential
  Manager is built on.
- **Linux / macOS:** plaintext in the app's preferences file. This is a
  known, accepted limitation — not an oversight. macOS Keychain and Linux
  libsecret backends are tracked follow-up work, tracked in the open
  issues. A report that merely restates this paragraph is out of scope;
  a working exploit that exfiltrates secrets *without* local user-level
  access is in scope.

## Scope Notes

This project ships a native networking engine. Reports most valuable to us:

- Unsafe FFI handling (invalid pointers, string lifetimes, panics crossing FFI).
- DLL/search-path hijacking in the native library loader.
- Input validation gaps where user input reaches sockets, processes, or FFI.
- Secret handling flaws beyond the disclosed platform gap above.

Out of scope: reports that the app performs network probing at all (that is
its documented purpose), or vulnerabilities in Flutter/Rust toolchains
themselves (report those upstream).

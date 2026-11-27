# Linux packages (.deb and .rpm)

`build-package.sh` wraps the release binary in a Debian package or an RPM.
Both formats install the same files and run the same systemd unit:

```text
/usr/bin/netstudio-headless
/lib/systemd/system/netstudio-headless.service
/etc/netstudio/targets.json          conffile, never overwritten on upgrade
/etc/default/netstudio-headless      conffile, extra daemon arguments
/usr/share/man/man1/netstudio-headless.1.gz
/usr/share/bash-completion/completions/netstudio-headless
/usr/share/zsh/{vendor-completions|site-functions}/_netstudio-headless
/usr/share/doc/netstudio-headless/{copyright,LICENSE,CHANGELOG.md}
```

The state file lives in `/var/lib/netstudio/` (created by `StateDirectory=`,
owned by `netstudio`) and is deliberately not packaged.

## Build

Run it on Linux with `dpkg-deb` or `rpmbuild` installed, after
`cargo build --release`:

```bash
cd native_engine && cargo build --release && cd ..
bash deploy/linux/build-package.sh --format deb --outdir dist
bash deploy/linux/build-package.sh --format rpm --outdir dist
bash deploy/linux/build-package.sh --format deb --arch arm64 --outdir dist
bash deploy/linux/build-package.sh --check        # assets only, no binary
```

**Build on the oldest distribution you support.** A binary linked against a
newer glibc refuses to start on an older one, and no packaging fixes that.
The release job therefore runs inside `debian:bullseye` (glibc 2.31), which
keeps a single build usable on Debian 11-13, Ubuntu 20.04+ and RHEL 9+;
`--glibc-min` writes the matching `Depends` line into the `.deb`.

`bullseye` itself has moved to `archive.debian.org`: the suite indexes still
come from `deb.debian.org`, but the package files only exist in the archive, so
a fresh `debian:bullseye` container must point apt there (with
`Acquire::Check-Valid-Until=false`) before installing the packaging tools. The
release job does this in `.github/workflows/release.yml`.

Both packages install the same architecture: `--arch amd64` (default) or
`--arch arm64`.

## Install, upgrade, remove

```bash
sudo dpkg -i dist/netstudio-headless_2.0.0_amd64.deb
sudo rpm -i dist/netstudio-headless-2.0.0-1.x86_64.rpm

sudo apt install -f          # resolve a missing libc6/adduser: dpkg does not

systemctl status netstudio-headless
journalctl -u netstudio-headless -f
systemctl reload netstudio-headless    # SIGHUP: re-read targets.json

sudo apt purge netstudio-headless      # also removes the user and /var/lib
sudo rpm -e netstudio-headless         # same cleanup on the RPM side
```

Replacing `/etc/netstudio/targets.json` by hand is safe: it is a conffile, so
an upgrade keeps your file and leaves the packaged default as
`targets.json.dpkg-dist` (or `.rpmnew`).

## What the unit does

`netstudio-headless.service` runs as the unprivileged `netstudio` account and
publishes on `127.0.0.1:9101` only. The packaged command line is

```text
--config /etc/netstudio/targets.json --listen 127.0.0.1:9101 \
  --output /var/lib/netstudio/status.json --watch-config 60 $NETSTUDIO_ARGS
```

so `systemctl reload` (SIGHUP) and file changes both apply a new target list
without restarting, and `/var/lib/netstudio/status.json` always holds the
latest snapshot.

Hardening: `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
`NoNewPrivileges`, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`
and `CapabilityBoundingSet=CAP_NET_RAW`. Only `CAP_NET_RAW` is ambient, and
only because ICMP needs a raw socket: delete both capability lines when the
configuration has no ICMP targets.

## Publishing beyond loopback

Put the extra flags in `/etc/default/netstudio-headless` rather than editing
the unit, which upgrades replace:

```bash
sudo install -d -o root -g netstudio -m 0750 /etc/netstudio
sudo install -o root -g netstudio -m 0640 /dev/null /etc/netstudio/token
sudo sh -c 'printf "%s\n" "$TOKEN" > /etc/netstudio/token'
echo 'NETSTUDIO_ARGS=--listen 0.0.0.0:9101 --http-token-file /etc/netstudio/token' \
  | sudo tee -a /etc/default/netstudio-headless
sudo systemctl restart netstudio-headless
```

`systemd-analyze verify /lib/systemd/system/netstudio-headless.service`
parses the unit without starting it; `netstudio-headless --check --config
/etc/netstudio/targets.json` validates the target file and the state path.

## SBOM

`tool/headless-sbom.py` writes a CycloneDX 1.5 document for the crates that
end up in the binary, with the checksums `Cargo.lock` already pins:

```bash
python3 tool/headless-sbom.py --output dist/netstudio-headless-2.0.0.cdx.json
```

It needs only `cargo metadata` (no build, no network beyond the registry
index) and the Python standard library; the release workflow attaches the
file next to the packages.

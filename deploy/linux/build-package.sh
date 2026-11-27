#!/usr/bin/env bash
# Build a .deb or .rpm for netstudio-headless from a release binary.
#
#   deploy/linux/build-package.sh --format deb
#   deploy/linux/build-package.sh --format rpm --arch arm64
#   deploy/linux/build-package.sh --check        # assets only, no binary
#
# Build on the oldest distribution you support: a binary linked against a
# newer glibc will not start on an older one. The default libc6 floor (2.31)
# assumes a debian:bullseye build, which keeps the package installable on
# Debian 11-13, Ubuntu 20.04+ and RHEL 9+.
set -euo pipefail

NAME=netstudio-headless
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
ASSETS=$SCRIPT_DIR

FORMAT=
ARCH=amd64
VERSION=
BINARY=
OUTDIR=$ROOT/dist
CHECK_ONLY=0
GLIBC_MIN=2.31
MAINTAINER="VeloceNet-Studio Contributors <maintainers@velocenet.studio>"
HOMEPAGE=https://github.com/Cadman021/VeloceNet-Studio

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: build-package.sh --format deb|rpm [options]

  --format deb|rpm   Package format to build.
  --arch amd64|arm64 Target architecture (default: amd64).
  --version X.Y.Z    Override the version read from native_engine/Cargo.toml.
  --binary PATH      Release binary (default: native_engine/target/release/netstudio-headless).
  --outdir DIR       Where the package lands (default: ./dist).
  --glibc-min X.Y    libc6 floor written into the .deb Depends (default: 2.31).
  --check            Verify the packaging assets and exit without building.
  -h, --help         This text.

Both formats install the same files:
  /usr/bin/netstudio-headless
  /lib/systemd/system/netstudio-headless.service
  /etc/netstudio/targets.json          (conffile, never overwritten)
  /etc/default/netstudio-headless      (conffile, extra arguments)
  /usr/share/man/man1/netstudio-headless.1.gz
  /usr/share/bash-completion/completions/netstudio-headless
  /usr/share/zsh/{vendor-completions|site-functions}/_netstudio-headless
  /usr/share/doc/netstudio-headless/{copyright,LICENSE,CHANGELOG.md}
EOF
}

while (($#)); do
    case $1 in
        --format) FORMAT=${2:?--format needs a value}; shift 2 ;;
        --format=*) FORMAT=${1#*=}; shift ;;
        --arch) ARCH=${2:?--arch needs a value}; shift 2 ;;
        --arch=*) ARCH=${1#*=}; shift ;;
        --version) VERSION=${2:?--version needs a value}; shift 2 ;;
        --version=*) VERSION=${1#*=}; shift ;;
        --binary) BINARY=${2:?--binary needs a value}; shift 2 ;;
        --binary=*) BINARY=${1#*=}; shift ;;
        --outdir) OUTDIR=${2:?--outdir needs a value}; shift 2 ;;
        --outdir=*) OUTDIR=${1#*=}; shift ;;
        --glibc-min) GLIBC_MIN=${2:?--glibc-min needs a value}; shift 2 ;;
        --glibc-min=*) GLIBC_MIN=${1#*=}; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

case $ARCH in
    amd64|x86_64) DEB_ARCH=amd64; RPM_ARCH=x86_64 ;;
    arm64|aarch64) DEB_ARCH=arm64; RPM_ARCH=aarch64 ;;
    *) die "unsupported --arch $ARCH (use amd64 or arm64)" ;;
esac

if [ -z "$VERSION" ]; then
    VERSION=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT/native_engine/Cargo.toml" | head -n 1)
fi
[ -n "$VERSION" ] || die "cannot read the version from native_engine/Cargo.toml; pass --version"

rpm_version=${VERSION%%-*}
rpm_release=1
if [[ $VERSION == *-* ]]; then
    rpm_release=${VERSION#*-}
fi

assets=(
    "$ASSETS/$NAME.service"
    "$ASSETS/$NAME.default"
    "$ASSETS/copyright"
    "$ASSETS/debian/postinst"
    "$ASSETS/debian/prerm"
    "$ASSETS/debian/postrm"
    "$ROOT/LICENSE"
    "$ROOT/CHANGELOG.md"
    "$ROOT/docs/netstudio-headless.1"
    "$ROOT/docs/examples/targets.json"
    "$ROOT/docs/completions/$NAME.bash"
    "$ROOT/docs/completions/$NAME.zsh"
)

missing=0
for asset in "${assets[@]}"; do
    if [ ! -f "$asset" ]; then
        printf 'missing: %s\n' "$asset" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || die "packaging assets are incomplete"

if [ "$CHECK_ONLY" -eq 1 ]; then
    printf 'assets OK: %d files for %s %s (%s)\n' "${#assets[@]}" "$NAME" "$VERSION" "$ARCH"
    printf 'binary: %s\n' "${BINARY:-$ROOT/native_engine/target/release/$NAME}"
    printf 'layout:\n'
    for path in \
        "/usr/bin/$NAME" \
        "/lib/systemd/system/$NAME.service" \
        "/etc/netstudio/targets.json" \
        "/etc/default/$NAME" \
        "/usr/share/man/man1/$NAME.1.gz" \
        "/usr/share/bash-completion/completions/$NAME" \
        "/usr/share/zsh/<vendor-completions|site-functions>/_$NAME" \
        "/usr/share/doc/$NAME/"; do
        printf '  %s\n' "$path"
    done
    exit 0
fi

[ -n "$FORMAT" ] || die "--format deb or --format rpm is required (see --help)"
case $FORMAT in
    deb|rpm) ;;
    *) die "unknown --format $FORMAT" ;;
esac

if [ -z "$BINARY" ]; then
    BINARY=$ROOT/native_engine/target/release/$NAME
fi
[ -x "$BINARY" ] || die "$BINARY is not executable; build it first: (cd native_engine && cargo build --release --locked)"

if [ "$FORMAT" = deb ]; then
    command -v dpkg-deb >/dev/null || die "dpkg-deb is not installed (apt-get install dpkg)"
else
    command -v rpmbuild >/dev/null || die "rpmbuild is not installed (apt-get install rpm)"
fi

mkdir -p "$OUTDIR"
OUTDIR=$(cd -- "$OUTDIR" && pwd)

stage=$(mktemp -d "${TMPDIR:-/tmp}/netstudio-pkg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
tree=$stage/tree

zsh_dir=site-functions
if [ "$FORMAT" = deb ]; then
    zsh_dir=vendor-completions
fi

install -Dm0755 "$BINARY" "$tree/usr/bin/$NAME"
install -Dm0644 "$ASSETS/$NAME.service" "$tree/lib/systemd/system/$NAME.service"
install -Dm0644 "$ASSETS/$NAME.default" "$tree/etc/default/$NAME"
install -Dm0644 "$ROOT/docs/examples/targets.json" "$tree/etc/netstudio/targets.json"
install -Dm0644 "$ROOT/docs/completions/$NAME.bash" "$tree/usr/share/bash-completion/completions/$NAME"
install -Dm0644 "$ROOT/docs/completions/$NAME.zsh" "$tree/usr/share/zsh/$zsh_dir/_$NAME"
install -Dm0644 "$ROOT/LICENSE" "$tree/usr/share/doc/$NAME/LICENSE"
install -Dm0644 "$ASSETS/copyright" "$tree/usr/share/doc/$NAME/copyright"
install -Dm0644 "$ROOT/CHANGELOG.md" "$tree/usr/share/doc/$NAME/CHANGELOG.md"
install -d "$tree/usr/share/man/man1"
gzip -9n -c "$ROOT/docs/netstudio-headless.1" > "$tree/usr/share/man/man1/$NAME.1.gz"
chmod 0644 "$tree/usr/share/man/man1/$NAME.1.gz"

if [ "$FORMAT" = deb ]; then
    root=$stage/deb
    mkdir -p "$root/DEBIAN"
    cp -a "$tree/." "$root/"
    size=$(du -sk "$tree" | cut -f1)
    cat > "$root/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $DEB_ARCH
Maintainer: $MAINTAINER
Installed-Size: $size
Depends: libc6 (>= $GLIBC_MIN), adduser
Recommends: systemd
Homepage: $HOMEPAGE
Description: headless probe daemon for VeloceNet Studio
 Measures latency, jitter and loss for ICMP, TCP, HTTP and HTTPS targets
 from one process, without the desktop application.
 .
 It writes the latest snapshot to /var/lib/netstudio/status.json, serves a
 JSON API and Prometheus metrics on 127.0.0.1:9101, and reloads
 /etc/netstudio/targets.json on SIGHUP (systemctl reload).
EOF
    printf '/etc/default/%s\n/etc/netstudio/targets.json\n' "$NAME" > "$root/DEBIAN/conffiles"
    for script in postinst prerm postrm; do
        install -Dm0755 "$ASSETS/debian/$script" "$root/DEBIAN/$script"
    done
    {
        printf '%s (%s) unstable; urgency=medium\n\n' "$NAME" "$VERSION"
        printf '  * Release %s of the VeloceNet Studio headless daemon.\n' "$VERSION"
        printf '    See /usr/share/doc/%s/CHANGELOG.md.\n\n' "$NAME"
        printf ' -- %s  %s\n' "$MAINTAINER" "$(LC_ALL=C date -u -R)"
    } | gzip -9n > "$root/usr/share/doc/$NAME/changelog.Debian.gz"
    chmod 0644 "$root/usr/share/doc/$NAME/changelog.Debian.gz"
    target=$OUTDIR/${NAME}_${VERSION}_${DEB_ARCH}.deb
    dpkg-deb --root-owner-group -Zxz --build "$root" "$target"
    printf 'built %s (%s)\n' "$target" "$(du -h "$target" | cut -f1)"
    dpkg-deb --info "$target" | sed -n '1,12p'
else
    top=$stage/rpmbuild
    mkdir -p "$top/SPECS"
    spec=$top/SPECS/$NAME.spec
    cat > "$spec" <<EOF
Name: $NAME
Version: $rpm_version
Release: $rpm_release
Summary: Headless probe daemon for VeloceNet Studio
License: GPL-3.0-or-later
URL: $HOMEPAGE
BuildArch: $RPM_ARCH
Requires: systemd
Requires(pre): shadow-utils
%global debug_package %{nil}

%description
Measures latency, jitter and loss for ICMP, TCP, HTTP and HTTPS targets from
one process, without the desktop application. Writes the latest snapshot to
/var/lib/netstudio/status.json, serves a JSON API and Prometheus metrics on
127.0.0.1:9101, and reloads /etc/netstudio/targets.json on SIGHUP.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a %{_sourcedir}/tree/. %{buildroot}/

%pre
getent group netstudio >/dev/null || groupadd -r netstudio
getent passwd netstudio >/dev/null || useradd -r -g netstudio -d /var/lib/netstudio -s /sbin/nologin -c "VeloceNet Studio headless daemon" netstudio

%post
if [ \$1 -eq 1 ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable --now netstudio-headless.service || :
else
    systemctl daemon-reload || :
fi

%preun
if [ \$1 -eq 0 ]; then
    systemctl stop netstudio-headless.service >/dev/null 2>&1 || :
    systemctl disable netstudio-headless.service >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :
if [ \$1 -eq 0 ]; then
    userdel netstudio >/dev/null 2>&1 || :
    groupdel netstudio >/dev/null 2>&1 || :
    rm -rf /var/lib/netstudio
fi

%files
/etc/default/netstudio-headless
%config(noreplace) /etc/netstudio/targets.json
/usr/bin/netstudio-headless
/lib/systemd/system/netstudio-headless.service
%doc /usr/share/doc/netstudio-headless
/usr/share/man/man1/netstudio-headless.1.gz
/usr/share/bash-completion/completions/netstudio-headless
/usr/share/zsh/site-functions/_netstudio-headless
EOF
    rpmbuild -bb \
        --define "_topdir $top" \
        --define "_sourcedir $stage" \
        --define "_build_id_links none" \
        "$spec"
    built=$top/RPMS/$RPM_ARCH/$NAME-$rpm_version-$rpm_release.$RPM_ARCH.rpm
    [ -f "$built" ] || die "rpmbuild produced no package (expected $built)"
    target=$OUTDIR/$NAME-$VERSION-$rpm_release.$RPM_ARCH.rpm
    cp "$built" "$target"
    printf 'built %s (%s)\n' "$target" "$(du -h "$target" | cut -f1)"
    if command -v rpm >/dev/null; then
        rpm -qip "$target" | sed -n '1,10p'
    fi
fi
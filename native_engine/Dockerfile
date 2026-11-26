# Standalone headless daemon image (no Flutter, no display).
# Build:  docker build -f native_engine/Dockerfile -t netstudio-headless:1.6.0 .
# Run:    docker run --rm -p 9101:9101 --cap-add NET_RAW \
#           -v $PWD/targets.json:/etc/netstudio/targets.json:ro netstudio-headless:1.6.0
#
# ICMP probes need a raw socket: --cap-add NET_RAW (or NET_ADMIN on some
# kernels). Without it ICMP targets fall back to TCP or report a permission
# error; TCP, HTTP and HTTPS probes work unprivileged.
FROM rust:1-bookworm AS build

WORKDIR /src
# Dependencies first: a source-only change then relinks this crate instead of
# rebuilding the whole tree. Stub sources satisfy cargo for this layer.
COPY native_engine/Cargo.toml native_engine/Cargo.lock ./
RUN mkdir -p src/bin \
    && printf 'fn main() {}\n' > src/lib.rs \
    && printf 'fn main() {}\n' > src/bin/netstudio-headless.rs \
    && cargo build --release --bin netstudio-headless \
    && rm -rf src
COPY native_engine/src ./src
RUN cargo build --release --bin netstudio-headless

FROM debian:bookworm-slim

# ca-certificates for outbound TLS tooling and proxy setups; the probe itself
# only records the presented certificate chain.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /var/lib/netstudio netstudio \
    && mkdir -p /var/lib/netstudio /etc/netstudio \
    && chown -R netstudio:netstudio /var/lib/netstudio

COPY --from=build /src/target/release/netstudio-headless /usr/local/bin/netstudio-headless

USER netstudio
WORKDIR /var/lib/netstudio
EXPOSE 9101

# Exec form: the daemon receives SIGTERM directly and stops gracefully.
ENTRYPOINT ["/usr/local/bin/netstudio-headless"]
CMD ["--config", "/etc/netstudio/targets.json", "--listen", "0.0.0.0:9101", "--output", "/var/lib/netstudio/status.json", "--log-format", "json"]

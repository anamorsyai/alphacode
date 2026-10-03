#!/bin/sh
# Build alphacode for aarch64-unknown-linux-musl inside an Alpine 3.22 docker
# container. Run by .github/workflows/build-alpine.yml with the repo mounted
# at /src; produces target/release/alphacode (musl-linked, NEEDED: libxkbcommon
# + libc.musl-aarch64) that runs on AlpineTerm/Alpine 3.2x aarch64 hosts.
#
# Runs inside the container as root:
# - git needs safe.directory because /src is owned by the host runner uid.
# - rustup installs the pinned 1.94.1 toolchain (rust-toolchain.toml MSRV;
#   apk's rust is far too old for the aws-sdk dependency tree).
# - The smoke test runs in the same container its runtime deps come from, so
#   a missing libxkbcommon or a bad musl link fails the build, not a release.
set -eux

apk add --no-cache build-base pkgconf libxkbcommon-dev git curl ca-certificates bash

git config --global --add safe.directory /src

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
  sh -s -- -y --default-toolchain 1.94.1 --profile minimal --no-self-update
. "$HOME/.cargo/env"

cargo build --release --locked

# Hard gate: must actually start inside the container.
./target/release/alphacode --version

# Informational: NEEDED should only be libxkbcommon + libc.musl-aarch64; a
# glibc library here means the musl build silently broke.
readelf -d target/release/alphacode | grep NEEDED || true

# Give the artifacts back to the runner user before unmounting.
chown "$(stat -c %u /src):$(stat -c %g /src)" target/release/alphacode

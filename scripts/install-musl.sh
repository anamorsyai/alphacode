#!/bin/sh
# Install alphacode from GitHub releases — musl static aarch64 build.
#
# Works on any aarch64 musl host (Alpine 3.x, AlpineTerm, postmarketOS):
# the binary is fully static, so no extra runtime libraries are needed.
# Installs to /root/.local/bin/alphacode with a symlink in /usr/local/bin
# (both typically on PATH). Idempotent: re-running updates in place.
#
# Release assets on a public repo, so no GitHub token is needed or used —
# past attempts to inline `alpctl github token` into --header broke the
# pipe-install path (token quoting + no alpctl under `curl | sh`).
#
# Usage: curl -fsSL https://raw.githubusercontent.com/anamorsyai/alphacode/main/scripts/install-musl.sh | sh
# Env override: ALPHACODE_RELEASE=v1.0.71 (default: latest release)

set -eu

REPO="${ALPHACODE_REPO:-anamorsyai/alphacode}"
ARCH=$(uname -m)
BIN_DIR="${ALPHACODE_BIN_DIR:-/root/.local/bin}"
LINK_DIR="/usr/local/bin"
TMP=$(mktemp -d /tmp/alphacode-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

say() { printf '%s\n' "$*"; }

case "$ARCH" in
  aarch64|arm64) ART="alphacode-linux-musl-aarch64" ;;
  *) say "ERROR: no musl build for $ARCH (only aarch64 is produced by build-alpine.yml)"; exit 1 ;;
esac

TAG="${ALPHACODE_RELEASE:-latest}"
if [ "$TAG" = "latest" ]; then
  say "Resolving latest release ..."
  TAG=$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$TAG" ] || { say "ERROR: could not resolve latest release (network or rate limit)"; exit 1; }
fi
say "Installing alphacode $TAG (musl static, $ARCH)"

BASE="https://github.com/$REPO/releases/download/$TAG"
say "Downloading ..."
wget -qO "$TMP/archive.tar.gz" "$BASE/$ART.tar.gz" ||
  { say "ERROR: download failed ($BASE/$ART.tar.gz)"; exit 1; }
if wget -qO "$TMP/checksums" "$BASE/$ART.sha256" 2>/dev/null && [ -s "$TMP/checksums" ]; then
  (cd "$TMP" && sha256sum -c checksums >/dev/null 2>&1) ||
    { say "ERROR: checksum mismatch — aborting"; exit 1; }
  say "Checksum OK"
else
  say "Note: checksum file unavailable, skipping verification"
fi

tar -xzf "$TMP/archive.tar.gz" -C "$TMP"
mkdir -p "$BIN_DIR"
chmod 755 "$TMP/alphacode"
mv "$TMP/alphacode" "$BIN_DIR/alphacode"
[ -d "$LINK_DIR" ] && ln -sf "$BIN_DIR/alphacode" "$LINK_DIR/alphacode"

V=$("$BIN_DIR/alphacode" --version 2>&1 | head -1)
say "Installed: $V"
say "Binary:    $BIN_DIR/alphacode"
say "Run:       alphacode --help"

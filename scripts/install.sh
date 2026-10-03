#!/usr/bin/env bash
# install.sh — one-line installer for Alphacode
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dragonked2/alphacode/main/scripts/install.sh | bash
#   curl -fsSL ... | bash -s -- --version v1.0.0
#   curl -fsSL ... | bash -s -- --prefix ~/.local
#
# Supported: Linux + macOS on x86_64 and aarch64.
#
# On musl-based Linux (Alpine, postmarketOS, AlpineTerm) aarch64 hosts, the
# glibc release artifact cannot start, so a static musl build is fetched
# instead; the glibc asset is tried first as a fallback for older releases.

set -euo pipefail

REPO="${ALPHACODE_REPO:-dragonked2/alphacode}"
VERSION="${ALPHACODE_VERSION:-latest}"
PREFIX="${ALPHACODE_PREFIX:-$HOME/.local}"
BIN_DIR="${ALPHACODE_BIN_DIR:-$PREFIX/bin}"
# If set to 1, never fall back to building from source (force release-only).
SOURCE_ONLY="${ALPHACODE_SOURCE_ONLY:-}"
# If set to 1, never try the release path — always build from source.
NEVER_RELEASE="${ALPHACODE_NEVER_RELEASE:-}"
# If set, the ref (branch / tag / sha) to check out when building from source.
SOURCE_REF="${ALPHACODE_SOURCE_REF:-}"

print() { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }
fail()  { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
install.sh — install Alphacode.

By default, tries to download a prebuilt release asset for your platform
from the GitHub release page. If no release is published (or there is no
asset for this OS/arch), it falls back to building from source.

Flags:
  --version <v>     Release tag to install (default: latest)
  --prefix <dir>    Install prefix (default: ~/.local)
  --bin-dir <dir>   Override the binary directory (default: <prefix>/bin)
  --add-path        Append the bin dir to your shell profile so `alphacode`
                    is on PATH in new shells. Detects bash/zsh/fish/nushell/
                    csh/ksh and is idempotent across re-runs.
  --link            Also symlink the binary into a system bin dir
                    (default /usr/local/bin) so no PATH change is needed at
                    all. Needs write access — re-run with sudo.
  --no-path         Do not print or configure PATH instructions at the end
  --from-source     Skip the release download and always build from source
  --source-only     Never fall back to building from source (release-only)
  --source-ref <r>  When building from source, check out this ref (branch/tag/sha)
  -h, --help        Show this help

Environment:
  ALPHACODE_REPO=<owner>/<repo>    Default: dragonked2/alphacode
  ALPHACODE_VERSION=<v>            Default: latest
  ALPHACODE_PREFIX=<dir>           Default: ~/.local
  ALPHACODE_BIN_DIR=<dir>          Default: <prefix>/bin
  ALPHACODE_LINK_DIR=<dir>         Default: /usr/local/bin (used by --link)
  ALPHACODE_NEVER_RELEASE=1        Alias for --from-source
  ALPHACODE_SOURCE_ONLY=1          Alias for --source-only
  ALPHACODE_SOURCE_REF=<ref>       Alias for --source-ref

Exit codes:
  0   installed successfully
  1   user error
  2   download failed
  3   checksum mismatch
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --prefix)  PREFIX="$2";  shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --add-path) ADD_PATH=1;   shift ;;
    --link)     LINK_BIN=1;   shift ;;
    --no-path) NO_PATH=1;    shift ;;
    --source-only) SOURCE_ONLY=1; shift ;;
    --from-source)  NEVER_RELEASE=1; shift ;;
    --source-ref)   SOURCE_REF="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown flag: $1 (try --help)" ;;
  esac
done

# --- build_from_source -------------------------------------------------------
#
# Fallback: no release artifact for this platform/arch. Clone the repo, build
# with cargo, and copy the resulting binary into $BIN_DIR.
#
# Requires: git, cargo, rustc >= 1.91, and a working C toolchain. This can
# take 5-30 minutes on a first build.
build_from_source() {
  command -v git   >/dev/null 2>&1 || fail "git is required to build from source"
  command -v cargo >/dev/null 2>&1 || fail "cargo is required to build from source (install Rust from https://rustup.rs)"

  # Make sure the toolchain is new enough for edition = "2024" and the
  # current dependency MSRV (mdwright-latex 0.1.3 requires rustc 1.91).
  local rust_ver
  rust_ver="$(rustc --version 2>/dev/null | awk '{print $2}')" || true
  if [ -n "$rust_ver" ]; then
    # Crude semver check: split major.minor.
    local major minor
    major="${rust_ver%%.*}"
    minor="$(echo "$rust_ver" | awk -F. '{print $2}')"
    if [ "${major:-0}" -lt 1 ] || { [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -lt 91 ]; }; then
      fail "rustc $rust_ver is too old; need >= 1.91 (update via 'rustup update')"
    fi
  fi

  local src_dir
  src_dir="$(mktemp -d)"
  # Chain the cleanup so we remove the build dir AND any earlier TMP.
  local _prev_tmp="${TMP:-}"
  trap 'rm -rf "$src_dir" ${_prev_tmp:+"$_prev_tmp"}' EXIT

  print "Cloning $REPO into a temporary build directory …"
  if [ -n "$SOURCE_REF" ]; then
    git clone --depth 1 --branch "$SOURCE_REF" "https://github.com/$REPO.git" "$src_dir/src" \
      || fail "git clone failed (ref: $SOURCE_REF)"
  else
    git clone --depth 1 "https://github.com/$REPO.git" "$src_dir/src" \
      || fail "git clone failed"
  fi

  print "Compiling alphacode (this can take 5-30 minutes on a first build) …"
  # NOTE: no --locked on purpose. The committed Cargo.lock does not list
  # platform-conditional deps (e.g. macOS-only core-graphics on a Linux user,
  # or vice-versa) for every target triple, and CI itself runs without
  # `--locked` (see .github/workflows/release.yml: `locked: false`). If we
  # passed --locked here, a fresh source build on a platform the lockfile
  # wasn't regenerated for would fail with "Cargo.lock needs to be updated".
  ( cd "$src_dir/src" && cargo build --release ) \
    || fail "cargo build failed"

  local built
  built="$(find "$src_dir/src/target/release" -maxdepth 1 -type f -name 'alphacode' -print -quit)"
  [ -n "$built" ] || fail "build succeeded but target/release/alphacode was not produced"

  mkdir -p "$BIN_DIR"
  install -m 0755 "$built" "$BIN_DIR/alphacode"
  print "Installed → $BIN_DIR/alphacode (built from source)"
}

# --- Sanity ------------------------------------------------------------------

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar   >/dev/null 2>&1 || fail "tar is required"

case "$(uname -s)" in
      Linux*) PLATFORM=linux ;;
      Darwin*) PLATFORM=macos ;;
      *) fail "unsupported OS: $(uname -s). On Windows run scripts/install.ps1 instead." ;;
    esac

case "$(uname -m)" in
      x86_64|amd64)  ARCH=x86_64 ;;
      aarch64|arm64) ARCH=arm64 ;;
      *) fail "unsupported architecture: $(uname -m)" ;;
    esac

# --- Pick a version ----------------------------------------------------------

# Short-circuit: build from source only.
if [ -n "$NEVER_RELEASE" ]; then
  print "--from-source requested, skipping release download."
  build_from_source
  exit 0
fi

if [ "$VERSION" = "latest" ]; then
  print "Resolving latest release from $REPO …"
  # NOTE: download the API response to a tempfile first, then parse it.
  # The previous `curl … | grep -m1 … | sed …` pipeline would race: as soon
  # as `grep -m1` matched `"tag_name"` and exited, the pipe closed and curl
  # got SIGPIPE on its next write → exit 23 (Failure writing output to
  # destination). The script then *incorrectly* thought no release existed
  # and fell through to a 5-30 minute source build. Buffering avoids the race.
  # NOTE: no `local` here — this block runs at the top level of the script
  # and bash only allows `local` inside a function. The variable name
  # (_api_tmp) is unique enough that global scope is harmless.
  _api_tmp="$(mktemp)"
  if curl -fsSL -o "$_api_tmp" "https://api.github.com/repos/$REPO/releases/latest"; then
    VERSION="$(grep -m1 '"tag_name"' "$_api_tmp" \
      | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')" || VERSION=""
  else
    VERSION=""
  fi
  rm -f "$_api_tmp"
  if [ -z "$VERSION" ]; then
    if [ -n "$SOURCE_ONLY" ]; then
      fail "no release found for $REPO and --source-only is set"
    fi
    warn "no GitHub release found for $REPO — falling back to building from source."
    build_from_source
    exit 0
  fi
  print "Latest release: $VERSION"
fi

# Some releases strip the leading 'v' in their published archives.
VERSION_NO_V="${VERSION#v}"

# --- Pick the release asset ----------------------------------------------------

# A glibc binary cannot start on a musl host (Alpine, postmarketOS, AlpineTerm):
# it dies with "Error loading shared library ld-linux-aarch64.so.1". Those hosts
# get a dedicated static musl artifact instead, named so it can never collide
# with the glibc one (see .github/workflows/build-alpine.yml).
#
# Detection is deliberately narrow: `ldd --version` on musl mentions musl and
# writes to stderr; on glibc it reports "ldd (GNU libc)". Hosts without ldd (some
# minimal images) fall through to the default glibc asset, and the source-build
# fallback below still catches them if that binary will not run.
IS_MUSL=0
if [ "$PLATFORM" = "linux" ] && command -v ldd >/dev/null 2>&1; then
  if ldd --version 2>&1 | grep -qi musl; then
    IS_MUSL=1
  fi
fi

# Candidate assets in preference order. On musl the musl build is tried first,
# then the glibc one, so releases published before this workflow existed (no musl
# artifact) still install instead of forcing a long source build.
if [ "$IS_MUSL" = "1" ] && [ "$ARCH" = "arm64" ]; then
  CANDIDATES="alphacode-linux-musl-aarch64.tar.gz
alphacode-linux-arm64.tar.gz"
  print "musl libc detected — preferring the static musl build."
else
  CANDIDATES="alphacode-${PLATFORM}-${ARCH}.tar.gz"
fi

# --- Download ----------------------------------------------------------------

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ASSET=""
for candidate in $CANDIDATES; do
  URL="https://github.com/$REPO/releases/download/${VERSION}/$candidate"
  print "Trying $URL"
  if curl -fL --retry 3 --connect-timeout 15 -o "$TMP/$candidate" "$URL"; then
    ASSET="$candidate"
    break
  fi
  rm -f "$TMP/$candidate"
done

if [ -z "$ASSET" ]; then
  if [ -n "$SOURCE_ONLY" ]; then
    fail "download failed (asset may not exist for $PLATFORM/$ARCH — try --version)"
  fi
  warn "no prebuilt asset for $PLATFORM/$ARCH at $VERSION — falling back to building from source."
  build_from_source
  exit 0
fi
URL="https://github.com/$REPO/releases/download/${VERSION}/$ASSET"
print "Downloaded $ASSET"

# Optional checksum verification.
if curl -fsSL -o "$TMP/SHA256SUMS" \
     "https://github.com/$REPO/releases/download/${VERSION}/SHA256SUMS" 2>/dev/null; then
  print "Verifying checksum …"
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$TMP" && sha256sum -c --ignore-missing < SHA256SUMS ) \
      || fail "checksum verification failed"
  else
    warn "sha256sum not available — skipping checksum verification"
  fi
fi

# --- Install -----------------------------------------------------------------

print "Extracting …"
tar -xzf "$TMP/$ASSET" -C "$TMP"

mkdir -p "$BIN_DIR"
FOUND="$(find "$TMP" -maxdepth 3 -type f -name 'alphacode' -print -quit)"
[ -n "$FOUND" ] || fail "extracted archive did not contain an 'alphacode' binary"

chmod +x "$FOUND"
mv "$FOUND" "$BIN_DIR/alphacode"

# Also move .bin payload files if present (release wrapper scripts need them).
find "$TMP" -maxdepth 3 -type f -name '*.bin' -print0 2>/dev/null | while IFS= read -r -d '' binfile; do
  mv "$binfile" "$BIN_DIR/"
done

print "Installed → $BIN_DIR/alphacode"

# --- Done --------------------------------------------------------------------

INSTALLED_VERSION="$("$BIN_DIR/alphacode" --version 2>/dev/null | sed -E 's/.*alphacode[[:space:]]+(v[0-9.]+).*/\1/' || echo unknown)"
if [ "$INSTALLED_VERSION" != "unknown" ]; then
  print "Installed version: $INSTALLED_VERSION"
else
  print "Installed (could not verify version)"
fi

# The prebuilt Linux binary links the system libxkbcommon (the `xa11y`
# accessibility backend is a hard dependency). Every desktop distro has it,
# but minimal server/container images often do not, and there the binary dies
# at startup with "error while loading shared libraries" — which the version
# check above would otherwise hide behind "could not verify version". Say what
# is actually wrong so the install does not look silently broken.
if [ "${PLATFORM:-}" = "linux" ] && ! "$BIN_DIR/alphacode" --version >/dev/null 2>&1; then
  if command -v ldd >/dev/null 2>&1; then
    MISSING_LIBS="$(ldd "$BIN_DIR/alphacode" 2>/dev/null | awk '/not found/ {print $1}' | sort -u | tr '\n' ' ')"
    if [ -n "$MISSING_LIBS" ]; then
      warn "alphacode cannot start: missing shared libraries: ${MISSING_LIBS% }"
      warn "install them, e.g.  sudo apt-get install -y libxkbcommon0   (Debian/Ubuntu)"
      warn "                   sudo dnf install -y libxkbcommon    (Fedora/RHEL)"
      warn "or build from source: bash install.sh --from-source"
    fi
  fi
fi

# --- path configuration ------------------------------------------------------
#
# Historically this script only *printed* `export PATH=...` and left the user
# to do it. That is the right default for `curl … | bash` — silently editing a
# dotfile is intrusive, and the script cannot know which file the user's login
# shell actually reads — but it means every bare server install ends with a
# manual step. `--add-path` and `--link` make the automatic path opt-in.

# Makes the profile edit idempotent: re-running the installer must not append a
# second, duplicate PATH line.
PATH_MARKER='# added by alphacode install.sh'

# Normalise the login shell to a lowercase basename (e.g. /bin/zsh -> zsh).
detect_shell() {
  local shell_path="${SHELL:-}"
  if [ -z "$shell_path" ] && command -v ps >/dev/null 2>&1; then
    shell_path="$(ps -p "$PPID" -o comm= 2>/dev/null || true)"
  fi
  [ -n "$shell_path" ] || return 1
  printf '%s\n' "${shell_path##*/}"
}

# Profile file to edit for a shell, or non-zero when we do not know it.
profile_for_shell() {
  case "$1" in
    bash)      printf '%s\n' "$HOME/.bashrc" ;;
    zsh)       printf '%s\n' "$HOME/.zshrc" ;;
    fish)      printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    nu|nushell) printf '%s\n' "$HOME/.config/nushell/config.nu" ;;
    csh|tcsh)  printf '%s\n' "$HOME/.tcshrc" ;;
    ksh)       printf '%s\n' "$HOME/.kshrc" ;;
    *)         return 1 ;;
  esac
}

# The line that prepends the bin dir to PATH in the given shell. Each shell has
# its own syntax; a POSIX `export` pasted into fish or nushell is a syntax error.
path_line_for_shell() {
  case "$1" in
    fish)
      printf '%s\n' "fish_add_path \"$2\" 2>/dev/null || set -gx PATH \"$2\" \$PATH"
      ;;
    nu|nushell)
      printf '%s\n' "\$env.PATH = [ \"$2\" ...\$env.PATH ]"
      ;;
    csh|tcsh)
      # csh has no `$path` array append; setenv prepends to PATH.
      printf '%s\n' "setenv PATH \"$2:\$PATH\""
      ;;
    *)
      printf '%s\n' "export PATH=\"$2:\$PATH\""
      ;;
  esac
}

add_bin_dir_to_path() {
  local shell profile
  if ! shell="$(detect_shell)"; then
    warn "could not detect your shell; add '$BIN_DIR' to PATH manually"
    return 1
  fi
  if ! profile="$(profile_for_shell "$shell")"; then
    warn "unsupported shell '$shell'; add '$BIN_DIR' to PATH manually"
    return 1
  fi
  if [ -f "$profile" ] && grep -qF "$PATH_MARKER" "$profile"; then
    print "'$profile' already configured for '$BIN_DIR'"
    return 0
  fi
  mkdir -p "$(dirname "$profile")"
  {
    printf '\n%s\n' "$PATH_MARKER"
    printf '%s\n' "$(path_line_for_shell "$shell" "$BIN_DIR")"
  } >> "$profile"
  print "added '$BIN_DIR' to PATH via $profile"
  print "open a new shell (or run: exec \$SHELL) to pick it up"
}

# Symlink into a system bin dir so `alphacode` resolves with no PATH edit.
link_into_system_bin() {
  local target="${ALPHACODE_LINK_DIR:-/usr/local/bin}"
  local link="$target/alphacode"
  if [ ! -d "$target" ]; then
    warn "$target does not exist; create it or use --add-path instead"
    return 1
  fi
  if [ ! -w "$target" ]; then
    warn "$target is not writable; re-run with sudo to create the symlink"
    return 1
  fi
  ln -sf "$BIN_DIR/alphacode" "$link"
  print "linked $link -> $BIN_DIR/alphacode"
}

if [ -n "${LINK_BIN:-}" ]; then
  link_into_system_bin || warn "symlink not created; '$BIN_DIR' still works"
fi

if [ -z "${NO_PATH:-}" ] && ! command -v alphacode >/dev/null 2>&1; then
  # Try the automatic route first when asked. If it cannot (unknown shell, no
  # profile), fall through to the manual instructions rather than leaving the
  # user with a warning and nothing to copy.
  if ! { [ -n "${ADD_PATH:-}" ] && add_bin_dir_to_path; }; then
    echo
    printf "\033[1;33mNext step:\033[0m add '%s' to your PATH.\n" "$BIN_DIR"
    printf "\033[0;90mOr re-run the installer with --add-path to do it for you.\033[0m\n"
    case ":$PATH:" in
      *":$BIN_DIR:"*) ;;
      *)
        cat <<PATH

  # Bash / Zsh — append to your ~/.bashrc or ~/.zshrc:
  export PATH="$BIN_DIR:\$PATH"

  # Fish:
  fish_add_path "$BIN_DIR"

  # Nushell:
  \$env.PATH = [ "$BIN_DIR" ...\$env.PATH ]
PATH
        ;;
    esac
  fi
fi

print "Run \`alphacode login\` to connect a model, then \`alphacode\` to start."
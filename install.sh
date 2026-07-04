#!/usr/bin/env bash
# install.sh — UNBLOCK CLI installer for Linux + macOS
#
# Usage:
#   curl -sSL install.kaeva.app | sh
#
# What it does (idempotent):
#   1. Detect OS (linux/darwin) + arch (x64/arm64)
#   2. If `unblock` is already on PATH and version >= remote latest, exit 2 (skip)
#   3. Download latest release artifact from
#      github.com/Viraj0518/unblock-install/releases/latest
#   4. Verify sha256 against SHA256SUMS published alongside the release
#   5. Install to $HOME/.local/bin/unblock (chmod +x, prepend to PATH in rc)
#   6. Print onboarding hint
#
# Exit codes:
#   0 success
#   1 failure
#   2 already installed (skipped)
#
# TODO(v2): cosign signature verification of the release artifact.
#           For v1 we rely on sha256 checksums + HTTPS to github.com.

set -eu

# ---------- config ----------
REPO="Viraj0518/unblock-install"
INSTALL_DIR="${UNBLOCK_INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="unblock"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t unblock-install)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- helpers ----------
log()  { printf '\033[1;36m[unblock-install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[unblock-install]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[unblock-install]\033[0m %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

require_one() {
  for cmd in "$@"; do
    if have "$cmd"; then echo "$cmd"; return 0; fi
  done
  err "missing required tool: need one of: $*"
  exit 1
}

# Downloader: curl or wget
DL_CMD="$(require_one curl wget)"
download() {
  url="$1"; out="$2"
  if [ "$DL_CMD" = "curl" ]; then
    curl -fsSL --retry 3 --retry-delay 1 -o "$out" "$url"
  else
    wget -q --tries=3 -O "$out" "$url"
  fi
}

# Hasher: sha256sum (linux) or shasum -a 256 (mac)
sha256() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}';
  elif have shasum;    then shasum -a 256 "$1" | awk '{print $1}';
  else err "no sha256 tool found (need sha256sum or shasum)"; exit 1; fi
}

# ---------- detect platform ----------
detect_os() {
  uname_s="$(uname -s)"
  case "$uname_s" in
    Linux*)   echo "linux" ;;
    Darwin*)  echo "darwin" ;;
    *)        err "unsupported OS: $uname_s"; exit 1 ;;
  esac
}

detect_arch() {
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) err "unsupported arch: $uname_m"; exit 1 ;;
  esac
}

# ---------- remote version ----------
fetch_latest_tag() {
  # Returns e.g. "v0.1.0"
  api_url="https://api.github.com/repos/${REPO}/releases/latest"
  tag_file="${TMP_DIR}/latest.json"
  if ! download "$api_url" "$tag_file"; then
    err "failed to fetch latest release metadata from ${api_url}"
    exit 1
  fi
  # Parse "tag_name": "v0.1.0" — no jq dependency
  tag="$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$tag_file" \
        | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
  if [ -z "$tag" ]; then
    err "could not parse tag_name from release metadata"
    exit 1
  fi
  echo "$tag"
}

# Strip leading "v" for semver compare
normalize_ver() { echo "${1#v}"; }

# Returns 0 if $1 >= $2 (semver, dot-separated, numeric only)
ver_ge() {
  a="$(normalize_ver "$1")"; b="$(normalize_ver "$2")"
  [ "$a" = "$b" ] && return 0
  # sort -V: greatest at bottom
  hi="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
  [ "$hi" = "$a" ]
}

# ---------- idempotency check ----------
check_already_installed() {
  remote_tag="$1"
  if ! have "$BIN_NAME"; then return 1; fi
  cur="$($BIN_NAME --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo "")"
  [ -z "$cur" ] && return 1
  if ver_ge "$cur" "$remote_tag"; then
    log "already installed: ${BIN_NAME} ${cur} (>= remote ${remote_tag})"
    return 0
  fi
  log "upgrading: ${cur} -> ${remote_tag}"
  return 1
}

# ---------- shell rc PATH ----------
add_to_path_rc() {
  bindir="$1"
  case ":$PATH:" in
    *":$bindir:"*) return 0 ;;
  esac
  line="export PATH=\"$bindir:\$PATH\""
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if ! grep -qsF "$line" "$rc" 2>/dev/null; then
      printf '\n# added by unblock-install\n%s\n' "$line" >> "$rc"
      log "added $bindir to PATH in $rc"
    fi
  done
  warn "open a new shell or run: export PATH=\"$bindir:\$PATH\""
}

# ---------- main ----------
main() {
  os="$(detect_os)"
  arch="$(detect_arch)"
  log "detected: ${os}-${arch}"

  remote_tag="$(fetch_latest_tag)"
  log "latest release: ${remote_tag}"

  if check_already_installed "$remote_tag"; then
    log "nothing to do — exit 2 (already installed, skipped)"
    exit 2
  fi

  # Asset naming convention: unblock-<os>-<arch>[.exe]
  # SHA256SUMS file lives in the same release.
  asset="${BIN_NAME}-${os}-${arch}"
  base_url="https://github.com/${REPO}/releases/download/${remote_tag}"
  asset_url="${base_url}/${asset}"
  sums_url="${base_url}/SHA256SUMS"

  asset_path="${TMP_DIR}/${asset}"
  sums_path="${TMP_DIR}/SHA256SUMS"

  log "downloading ${asset_url}"
  if ! download "$asset_url" "$asset_path"; then
    err "failed to download ${asset_url}"
    err "no ${os}-${arch} binary in release ${remote_tag}."
    err "see published assets: https://github.com/${REPO}/releases/${remote_tag}"
    exit 1
  fi

  log "downloading SHA256SUMS"
  if download "$sums_url" "$sums_path"; then
    # Match the asset whether listed as "<hash>  name" (text mode) or
    # "<hash> *name" (sha256sum binary mode — the leading * must be tolerated).
    expected="$(grep -E "[[:space:]][*]?${asset}\$" "$sums_path" | awk '{print $1}' | head -n1)"
    if [ -z "$expected" ]; then
      warn "no checksum entry for ${asset} in SHA256SUMS — skipping verify"
    else
      actual="$(sha256 "$asset_path")"
      if [ "$expected" != "$actual" ]; then
        err "sha256 mismatch! expected=${expected} actual=${actual}"
        exit 1
      fi
      log "sha256 verified"
    fi
  else
    warn "SHA256SUMS not found in release — skipping checksum verify"
  fi

  mkdir -p "$INSTALL_DIR"
  install_path="${INSTALL_DIR}/${BIN_NAME}"
  mv "$asset_path" "$install_path"
  chmod +x "$install_path"
  log "installed to ${install_path}"

  add_to_path_rc "$INSTALL_DIR"

  cat <<EOF

------------------------------------------------------------
  unblock ${remote_tag} installed.

  Now run:
    unblock spawn <bin> --as <name> --role member
  (or:
    unblock login <invite-code> --persona <name> )

  This installer only places the binary — your ~/.unblock data
  (identity, comms, saved state) is untouched and safe to reinstall over.
------------------------------------------------------------
EOF
  exit 0
}

main "$@"

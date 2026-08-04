#!/usr/bin/env bash
# install.sh — UNBLOCK CLI installer for Linux + macOS
#
# Usage:
#   curl -sSL install.kaeva.app | sh
#
# Env knobs (all optional):
#   UNBLOCK_VERSION=vX.Y.Z    pin the version to install — skips ALL release-
#                             metadata resolution (GitHub-API-independent)
#   UNBLOCK_INSTALL_DIR=DIR   install target (default ~/.local/bin)
#   UNBLOCK_NO_MODIFY_PATH=1  never touch shell rc files; print advice instead
#   UNBLOCK_LATEST_URL=URL    override the release-pointer endpoint
#
# What it does (idempotent):
#   1. Detect OS (linux/darwin) + arch (x64/arm64)
#   2. Resolve the version: UNBLOCK_VERSION pin, else the CF-edge-cached
#      pointer at install.kaeva.app/api/cli-latest, else api.github.com
#   3. If `unblock` is already on PATH and version >= that, exit 2 (skip);
#      otherwise download the release artifact from
#      github.com/Kaeva-labs/unblock-install/releases/latest
#   4. Verify sha256 against SHA256SUMS published alongside the release
#   5. Install to $HOME/.local/bin/unblock (chmod +x, prepend to PATH in rc)
#   6. Print onboarding hint
#
# Exit codes:
#   0 success
#   1 failure
#   2 already installed (skipped — including a concurrent-install race loser
#     whose box already ended up with a satisfying binary)
#
# Signature verification: release artifacts are checked via sha256
# checksums (see below) delivered over HTTPS to github.com. Cryptographic
# artifact signing is not yet implemented.

set -eu

# ---------- config ----------
REPO="Kaeva-labs/unblock-install"
INSTALL_DIR="${UNBLOCK_INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="unblock"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t unblock-install)"
trap 'rm -rf "$TMP_DIR"; release_lock' EXIT

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

# Metadata fetches get per-source budgets. The pointer is CF-edge-fronted: a
# healthy answer is sub-second, so it gets ONE fast, hard-capped try — a
# hanging pointer must never stall the install (≤~15s worst case, then we
# move on). The API source is the one that 504s transiently under shared-NAT
# rate limiting (seen live 4x in a row, 2026-07-28) — it gets patience:
# retries with real backoff, still time-capped. Old behavior was ~4s of
# retrying, then a hard red.
download_meta() {
  url="$1"; out="$2"; budget="$3"
  if [ "$DL_CMD" = "curl" ]; then
    if [ "$budget" = "fast" ]; then
      curl -fsSL --retry 1 --connect-timeout 5 --max-time 10 --retry-max-time 15 -o "$out" "$url"
    else
      # No --retry-delay: curl then backs off exponentially (1s, 2s, 4s, 8s).
      curl -fsSL --retry 4 --connect-timeout 5 --max-time 40 --retry-max-time 60 -o "$out" "$url"
    fi
  else
    if [ "$budget" = "fast" ]; then
      wget -q --tries=1 --timeout=10 -O "$out" "$url"
    else
      wget -q --tries=4 --waitretry=2 --timeout=15 -O "$out" "$url"
    fi
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
# Parse "tag_name": "v0.1.0" from a GitHub-shaped JSON body — no jq dependency.
# Both the install.kaeva.app pointer and api.github.com return this shape.
parse_tag_name() {
  grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" \
    | head -n1 | sed 's/.*"\([^"]*\)"$/\1/'
}

fetch_latest_tag() {
  # Version pin: skips ALL metadata resolution, so the install works even
  # when both metadata sources are down (asset downloads use the release
  # CDN, not the API). This is the stage/demo escape hatch.
  if [ -n "${UNBLOCK_VERSION:-}" ]; then
    # Normalize: accept 0.1.7 / v0.1.7 / V0.1.7, emit v0.1.7 (tags are vX.Y.Z).
    v="${UNBLOCK_VERSION#v}"; v="${v#V}"
    echo "v${v}"
    return 0
  fi

  # Primary: our own CF-fronted, edge-cached pointer — not subject to
  # api.github.com's unauthenticated 60 req/hr/IP limit (shared across a
  # whole NAT), which 504-killed live installs on 2026-07-28.
  # Fallback: api.github.com direct — same JSON shape, same parser, so a
  # pointer outage can never make an install worse than the old behavior.
  pointer_url="${UNBLOCK_LATEST_URL:-https://install.kaeva.app/api/cli-latest}"
  api_url="https://api.github.com/repos/${REPO}/releases/latest"
  tag_file="${TMP_DIR}/latest.json"
  # "<budget> <url>" pairs — URLs cannot contain raw spaces, so the split is safe.
  for attempt in "fast ${pointer_url}" "patient ${api_url}"; do
    budget="${attempt%% *}"; src="${attempt#* }"
    if download_meta "$src" "$tag_file" "$budget"; then
      tag="$(parse_tag_name "$tag_file")"
      if [ -n "$tag" ]; then echo "$tag"; return 0; fi
      warn "could not parse tag_name from ${src} — trying next source"
    else
      warn "failed to fetch release metadata from ${src} — trying next source"
    fi
  done
  err "could not resolve the latest release from any source:"
  err "  ${pointer_url}"
  err "  ${api_url}"
  err "if this is a network blip, re-run in a minute — or pin a version and"
  err "skip resolution entirely (releases: github.com/${REPO}/releases):"
  err "  curl -fsSL https://install.kaeva.app | UNBLOCK_VERSION=vX.Y.Z sh"
  exit 1
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
# PATH_HINT_NEEDED=1 means the install dir was NOT already on PATH when we
# ran — the final banner then prints exact, shell-honest instructions.
PATH_HINT_NEEDED=0
add_to_path_rc() {
  bindir="$1"
  case ":$PATH:" in
    *":$bindir:"*) return 0 ;;
  esac
  PATH_HINT_NEEDED=1
  if [ -n "${UNBLOCK_NO_MODIFY_PATH:-}" ]; then
    log "UNBLOCK_NO_MODIFY_PATH set — leaving shell rc files untouched"
    return 0
  fi
  line="export PATH=\"$bindir:\$PATH\""
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if ! grep -qsF "$line" "$rc" 2>/dev/null; then
      printf '\n# added by unblock-install\n%s\n' "$line" >> "$rc"
      log "added $bindir to PATH in $rc"
    fi
  done
}

# ---------- concurrency guard ----------
# A fleet-wide "upgrade now" can land N concurrent installer runs on one box
# (seen live 2026-07-25: two runs raced one install dir; the loser's mv failed
# AFTER the winner had already placed the right binary, misreporting a healthy
# box as a failed install). mkdir is atomic on linux+darwin, so a lock dir
# serializes the download+swap; a loser that wakes up to a satisfied install
# is the documented exit-2 case, not a failure.
LOCK_HELD=0
LOCK_DIR=""
acquire_lock() {
  LOCK_DIR="${INSTALL_DIR}/.unblock-install.lock"
  tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # Liveness beats age: the holder records its PID; if that process is
    # gone (kill -0 fails), the lock is stale NOW — no ten-minute wait. The
    # age check remains as fallback for a lock with no readable pid file.
    holder_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")"
    if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
      warn "removing stale install lock (holder pid ${holder_pid} no longer running): ${LOCK_DIR}"
      rm -rf "$LOCK_DIR"
      continue
    fi
    if [ -z "$holder_pid" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      warn "removing stale install lock (>10 min old, no holder pid): ${LOCK_DIR}"
      rm -rf "$LOCK_DIR"
      continue
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 60 ]; then
      return 1
    fi
    log "another install is running (lock ${LOCK_DIR}) — waiting 5s (${tries}/60)"
    sleep 5
  done
  echo "$$" > "${LOCK_DIR}/pid" 2>/dev/null || true
  LOCK_HELD=1
  return 0
}
release_lock() {
  if [ "$LOCK_HELD" = 1 ]; then rm -rf "$LOCK_DIR" 2>/dev/null || true; fi
  LOCK_HELD=0
}

# True if the binary AT $1 (not whatever PATH resolves — a race loser's PATH
# may not see the winner's fresh install) already satisfies version $2.
installed_at_path_satisfies() {
  bin="$1"; want="$2"
  [ -x "$bin" ] || return 1
  cur="$("$bin" --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo "")"
  [ -n "$cur" ] && ver_ge "$cur" "$want"
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

  mkdir -p "$INSTALL_DIR"
  install_path="${INSTALL_DIR}/${BIN_NAME}"
  if ! acquire_lock; then
    if installed_at_path_satisfies "$install_path" "$remote_tag"; then
      log "install lock never freed, but ${install_path} already satisfies ${remote_tag} — already installed (exit 2)"
      exit 2
    fi
    err "another install has held the lock for 5+ minutes and no satisfying binary appeared (${LOCK_DIR})."
    err "it may be on a very slow download — rerun once it completes, or remove the lock dir if nothing is running: rm -rf '${LOCK_DIR}'"
    exit 1
  fi
  # Another run may have finished while we waited on the lock.
  if installed_at_path_satisfies "$install_path" "$remote_tag"; then
    log "a concurrent install already placed ${BIN_NAME} >= ${remote_tag} — nothing to do (exit 2)"
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

  # The target can be mid-execution elsewhere or transiently locked — retry
  # briefly, then tell the truth: a failed swap over an already-satisfying
  # binary is the exit-2 case, never a false red on a healthy box.
  swapped=0
  for attempt in 1 2 3; do
    if mv -f "$asset_path" "$install_path" 2>/dev/null; then swapped=1; break; fi
    warn "binary swap failed (attempt ${attempt}/3) — retrying in 2s"
    sleep 2
  done
  if [ "$swapped" != 1 ]; then
    if installed_at_path_satisfies "$install_path" "$remote_tag"; then
      log "swap failed but ${install_path} already satisfies ${remote_tag} (a concurrent install won) — exit 2"
      exit 2
    fi
    err "failed to install to ${install_path} after 3 attempts (target in use?)"
    exit 1
  fi
  chmod +x "$install_path"
  log "installed to ${install_path}"

  add_to_path_rc "$INSTALL_DIR"

  # PATH truth, not PATH optimism: rc files are read by interactive/login
  # shells ONLY — the same shell that ran this installer, and any
  # `bash -c` / CI step / script, will NOT see the binary without the
  # export (or the full path). Say exactly that.
  path_block=""
  if [ "$PATH_HINT_NEEDED" = 1 ]; then
    if [ -n "${UNBLOCK_NO_MODIFY_PATH:-}" ]; then
      rc_note="  (Shell rc files were left untouched: UNBLOCK_NO_MODIFY_PATH is set,
  so EVERY new shell needs that export too.)"
    else
      rc_note="  New interactive shells pick it up automatically (added to your
  shell rc). Scripts, CI, and \`bash -c\` do NOT read rc files — they
  need the export above, or the full path: ${install_path}"
    fi
    path_block="
  To use it in THIS shell, first run:
    export PATH=\"${INSTALL_DIR}:\$PATH\"

${rc_note}
"
  fi

  cat <<EOF

------------------------------------------------------------
  unblock ${remote_tag} installed to ${install_path}
${path_block}
  Now run:
    unblock login          # sign in -- or create your account
  then:
    unblock initialize     # connect to your org-brain

  This installer only places the binary — your ~/.unblock data
  (identity, comms, saved state) is untouched and safe to reinstall over.
------------------------------------------------------------
EOF
  exit 0
}

main "$@"

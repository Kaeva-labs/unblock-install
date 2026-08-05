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
#   UNBLOCK_NO_VERIFY=1       skip the post-install execution check (loud warn).
#                             Only for hosts that cannot exec the artifact at
#                             all (cross-arch staging, no-exec sandboxes).
#   UNBLOCK_VERIFY_TIMEOUT=N  seconds the verification run may take (default 20)
#
# What it does (idempotent):
#   1. Detect OS (linux/darwin) + arch (x64/arm64)
#   2. Resolve the version: UNBLOCK_VERSION pin, else the CF-edge-cached
#      pointer at install.kaeva.app/api/cli-latest, else api.github.com
#   3. If `unblock` is already on PATH and version >= that, exit 2 (skip);
#      otherwise download the release artifact from
#      github.com/Kaeva-labs/unblock-install/releases/latest
#   4. Verify sha256 against SHA256SUMS published alongside the release
#   5. Install to $HOME/.local/bin/unblock (chmod +x)
#   6. RUN the installed binary and require rc=0 AND non-empty output — a
#      downloaded-and-chmodded file is not a working CLI (see below)
#   7. Prepend to PATH in rc, print onboarding hint
#
# Exit codes:
#   0 success
#   1 failure — including "installed, but the binary does not execute here",
#     which used to be reported as success
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
# Note this (and check_already_installed) EXECUTE the binary and require a
# version string back, so a binary that dies silently can never satisfy the
# skip check — the exit-2 path cannot be reached by a dead install.
installed_at_path_satisfies() {
  bin="$1"; want="$2"
  [ -x "$bin" ] || return 1
  cur="$("$bin" --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo "")"
  [ -n "$cur" ] && ver_ge "$cur" "$want"
}

# ---------- post-install verification ----------
# The installer used to stop at `chmod +x` and declare success. On Apple
# Silicon that is a LIE: an UNSIGNED arm64 Mach-O is SIGKILLed by the kernel
# at exec time, before main() ever runs — so the binary yields rc=137 and
# ZERO bytes on both stdout and stderr. That empty-output detail is what makes
# this class dangerous: a naive check that only scrapes stdout for a version
# string sees no error text and passes. The check must therefore EXECUTE the
# binary and require BOTH rc=0 AND non-empty output; either alone is a false
# green.
#
# Re-verified live 2026-08-05 against the published v0.1.7 darwin-arm64 asset
# (sha 1191be25…, matches the release SHA256SUMS), xattrs cleared so quarantine
# is not a variable — one variable changed, outcome flips:
#   as published (unsigned)                  -> rc=137, 0 bytes
#   SAME BYTES, `codesign -s - --force`      -> rc=0,   "0.1.7"
#   SAME BYTES, ad-hoc + `-o runtime`, no ent-> rc=133, 0 bytes
VERIFY_TIMEOUT="${UNBLOCK_VERIFY_TIMEOUT:-20}"
# A non-numeric budget would make the watchdog's `sleep` fail, silently
# removing the cap. Fall back rather than lose it.
case "$VERIFY_TIMEOUT" in
  ''|*[!0-9]*|0) warn "ignoring invalid UNBLOCK_VERIFY_TIMEOUT='${VERIFY_TIMEOUT}' — using 20s"
                 VERIFY_TIMEOUT=20 ;;
esac

# run_capped <outfile> <cmd> [args...] — run under a wall-clock cap, combined
# output to <outfile>, exit status echoed to stdout.
#
# Stock macOS has no timeout(1), so the cap is a plain background watchdog. Two
# properties are load-bearing:
#   * a watchdog kill is reported as 124 (timeout(1)'s convention), NEVER 137.
#     Mistaking our own SIGKILL for the kernel's would misdiagnose the exact
#     bug this function exists to catch.
#   * stdin is /dev/null. Under `curl … | sh` the SCRIPT ITSELF is on stdin; a
#     child that reads stdin would swallow the rest of the installer.
run_capped() {
  cap_out="$1"; shift
  cap_flag="${TMP_DIR}/verify.timedout"
  rm -f "$cap_flag" 2>/dev/null || true
  : > "$cap_out" 2>/dev/null || true

  "$@" >"$cap_out" 2>&1 </dev/null &
  cap_pid=$!
  # STDOUT MUST BE REDIRECTED HERE. run_capped is called inside $(...), so this
  # backgrounded block inherits the write end of that command-substitution pipe.
  # `kill "$cap_watch"` reaps the subshell but NOT the `sleep` it is blocked in;
  # the orphaned sleep keeps the pipe open, so $(...) cannot return until the
  # full budget elapses. Without `>/dev/null` the cap becomes a FLOOR and every
  # install stalls for VERIFY_TIMEOUT on success as well as failure.
  { sleep "$VERIFY_TIMEOUT"
    if kill -0 "$cap_pid" 2>/dev/null; then
      : > "$cap_flag"
      kill -9 "$cap_pid" 2>/dev/null || true
    fi
  } </dev/null >/dev/null 2>/dev/null &
  cap_watch=$!

  cap_status=0
  wait "$cap_pid" 2>/dev/null || cap_status=$?
  kill "$cap_watch" 2>/dev/null || true
  wait "$cap_watch" 2>/dev/null || true
  if [ -f "$cap_flag" ]; then cap_status=124; fi
  echo "$cap_status"
}

# Print the cause-specific diagnosis for a failed verification.
#
# There are TWO silent-death exit codes in this family. They are identical from
# the user's seat (no output whatsoever) and they need OPPOSITE fixes, so they
# must never be collapsed into one message:
#
#   137 = 128+9  SIGKILL — unsigned arm64. The arm64 kernel refuses to map
#                 unsigned code. ANY signature fixes it, even ad-hoc.
#   133 = 128+5  SIGTRAP — signed WITH the hardened runtime but with no
#                 entitlements, so the JIT the embedded engine needs is denied.
#                 Fixed by com.apple.security.cs.allow-jit, NOT by re-signing.
#
# A user told "unsigned" when the real problem is entitlements will go re-sign
# a binary that is already signed and get nowhere.
explain_verify_failure() {
  bin="$1"; vrc="$2"; vos="$3"; varch="$4"

  if [ "$vos" = "darwin" ] && have codesign; then
    csline="$(codesign -dv "$bin" 2>&1 | grep -E 'not signed|CodeDirectory' | head -n1 || true)"
    [ -n "$csline" ] && err "  codesign says: ${csline}"
  fi

  case "$vrc" in
    137)
      if [ "$vos" = "darwin" ] && [ "$varch" = "arm64" ]; then
        err "CAUSE: this arm64 binary is not code-signed."
        err "  Apple Silicon SIGKILLs unsigned arm64 code at exec time, before the"
        err "  program starts — which is why there is no output at all to read."
        err "  This is NOT Gatekeeper, NOT quarantine, and NOT an out-of-memory kill;"
        err "  the download itself was sha256-verified against the published sums."
        err "WHAT YOU CAN DO NOW:"
        err "  1. Ad-hoc sign the copy already on disk — that alone makes it run:"
        err "       codesign -s - --force '${bin}' && '${bin}' --version"
        err "     Re-running this installer would overwrite that signature with a"
        err "     fresh unsigned download, so put it on PATH by hand instead:"
        err "       export PATH=\"${INSTALL_DIR}:\$PATH\""
        err "  2. Or install the last release known to run as published:"
        err "       curl -fsSL https://install.kaeva.app | UNBLOCK_VERSION=v0.1.5 sh"
      else
        err "CAUSE: the process was SIGKILLed (137) by the OS."
        err "  On this platform that usually means out-of-memory or an external"
        err "  kill (container memory cap, cgroup limit, security agent)."
        err "WHAT YOU CAN DO NOW: re-run with more free memory, then run"
        err "  '${bin} --version' by hand to see whether it survives."
      fi
      ;;
    133)
      if [ "$vos" = "darwin" ]; then
        err "CAUSE: the binary is signed WITH the hardened runtime but is missing the"
        err "  JIT entitlement, so its JavaScript engine is denied the executable"
        err "  memory it needs and traps (SIGTRAP) instantly. The signature is FINE —"
        err "  re-signing alone will not fix this; the entitlement is what is missing."
        err "WHAT YOU CAN DO NOW:"
        err "  1. Re-sign without the hardened runtime, which drops the restriction:"
        err "       codesign -s - --force '${bin}' && '${bin}' --version"
        err "  2. Or re-sign keeping the runtime and granting JIT:"
        err "       com.apple.security.cs.allow-jit (in --entitlements)"
      else
        err "CAUSE: the process took SIGTRAP (133) and died before reporting."
        err "  On ${vos} that is a build/runtime fault, not a signing problem."
        err "WHAT YOU CAN DO NOW: run '${bin} --version' by hand and report the"
        err "  output at https://github.com/${REPO}/issues"
      fi
      ;;
    124)
      err "CAUSE: the binary did not finish '--version' within ${VERIFY_TIMEOUT}s and was"
      err "  stopped. It may be hung on a network call or waiting on input."
      err "WHAT YOU CAN DO NOW: run '${bin} --version' by hand to watch it, or"
      err "  re-run with a longer budget: UNBLOCK_VERIFY_TIMEOUT=60"
      ;;
    126|127)
      err "CAUSE: the file could not be executed at all (${vrc}) — wrong platform"
      err "  build, a missing loader/library, or a noexec mount at ${INSTALL_DIR}."
      err "WHAT YOU CAN DO NOW: check 'file ${bin}' matches ${vos}-${varch}, and"
      err "  install somewhere executable: UNBLOCK_INSTALL_DIR=/some/dir"
      ;;
    *)
      if [ "$vrc" -gt 128 ] 2>/dev/null; then
        err "CAUSE: killed by signal $((vrc - 128)) before it could report a version."
      else
        err "CAUSE: the binary ran but did not report a version cleanly."
      fi
      err "WHAT YOU CAN DO NOW: run '${bin} --version' by hand and report the"
      err "  output at https://github.com/${REPO}/issues"
      ;;
  esac
}

# Execute the freshly-installed binary. Returns 0 only if it truly works.
verify_install() {
  bin="$1"; want="$2"; vos="$3"; varch="$4"

  if [ -n "${UNBLOCK_NO_VERIFY:-}" ]; then
    warn "UNBLOCK_NO_VERIFY set — skipping the post-install execution check."
    warn "the binary at ${bin} has NOT been proven to run on this machine."
    return 0
  fi

  log "verifying the installed binary actually runs"
  vout="${TMP_DIR}/verify.out"
  vrc="$(run_capped "$vout" "$bin" --version)"
  # Command substitution strips trailing newlines, so a binary that emits only
  # whitespace reads as empty here — which is the honest answer.
  vtext="$(cat "$vout" 2>/dev/null || true)"

  if [ "$vrc" = "0" ] && [ -n "$vtext" ]; then
    log "verified: it executes and reports \"$(head -n1 "$vout")\""
    return 0
  fi

  if [ -n "$vtext" ]; then
    shown="$(head -n3 "$vout" | tr '\n' ' ')"
  else
    shown="<none — zero bytes on stdout AND stderr>"
  fi

  err "POST-INSTALL VERIFICATION FAILED — ${BIN_NAME} ${want} was placed at"
  err "  ${bin} but it does not run on this machine, so the install is NOT usable."
  err "  command:   ${bin} --version"
  err "  exit code: ${vrc}"
  err "  output:    ${shown}"
  explain_verify_failure "$bin" "$vrc" "$vos" "$varch"
  err "Tracking issue: https://github.com/${REPO}/issues/20"
  if [ "${REPLACED_PRIOR:-0}" = "1" ]; then
    err "(THIS WAS AN UPGRADE: a binary already existed at ${bin} and has been"
    err "  OVERWRITTEN by this broken one, so ${BIN_NAME} on your PATH is now"
    err "  non-functional. To get back to a working state immediately, reinstall a"
    err "  known-good version:  UNBLOCK_VERSION=v0.1.5 curl -fsSL https://install.kaeva.app | sh"
    err "  Nothing under ~/.unblock was modified.)"
  else
    err "(Your shell rc files were left untouched — a broken install does not get"
    err "  wired into your PATH. Nothing under ~/.unblock was modified.)"
  fi
  return 1
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
  # Did a binary already live here? Decides whether a failed verification means
  # "nothing was wired up" (fresh install) or "we just replaced something that
  # worked" (upgrade) — the two need opposite advice, and telling an upgrader
  # their PATH is untouched is false: mv -f below overwrites in place.
  REPLACED_PRIOR=0
  [ -e "$install_path" ] && REPLACED_PRIOR=1
  export REPLACED_PRIOR

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

  # Prove it before promising it. Deliberately BEFORE add_to_path_rc: an
  # install that cannot run must not be wired into the user's shell rc, and
  # every remedy printed on failure uses the absolute path anyway.
  if ! verify_install "$install_path" "$remote_tag" "$os" "$arch"; then
    exit 1
  fi

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

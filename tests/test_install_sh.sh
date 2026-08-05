#!/usr/bin/env bash
# tests/test_install_sh.sh — integration tests for install.sh
#
# Strategy: mock the GitHub API + release asset with a tiny local HTTP server,
# point install.sh at it via env override, and assert:
#   - fresh install lands the binary at the expected path with +x
#   - second run with same version exits 2 (idempotency)
#   - bad sha256 in SHA256SUMS causes exit 1
#   - --version reports the mocked version (proxied through the fake binary)
#   - a binary that does not EXECUTE fails the install loudly (tests 8-12)
#
# Tests 8-12 cover the class from issue #20: a downloaded, sha-verified,
# chmod +x'd file that cannot actually run. Every member of that class emits
# ZERO bytes, so the fixtures below reproduce the exact exit codes seen live
# rather than printing an error the installer could cheat off:
#   kill -9    $$ -> 137 (SIGKILL, what an unsigned arm64 Mach-O does)
#   kill -TRAP $$ -> 133 (SIGTRAP, what hardened-runtime-without-JIT does)
#   exit 0, silent -> the false green a stdout-only check would wave through
#
# Runs in a temp $HOME so it never touches the real install.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL_SH="$ROOT/install.sh"

# The public entrypoint is `curl | sh` — run the installer under sh (dash on
# Debian/Ubuntu), not bash, so bashisms fail here before they fail live.
INSTALL_SHELL="${INSTALL_TEST_SHELL:-sh}"

PASS=0; FAIL=0
TESTDIR="$(mktemp -d 2>/dev/null || mktemp -d -t unblock-test)"
trap 'rm -rf "$TESTDIR"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[32m  PASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '\033[31m  FAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# ---------- mock server ----------
# We can't easily intercept api.github.com without modifying install.sh,
# so we run install.sh in "mock mode": override REPO base URLs via a small
# patched copy that redirects to localhost.
SERVER_PORT="${SERVER_PORT:-8731}"
SERVER_ROOT="$TESTDIR/server"
mkdir -p "$SERVER_ROOT/api" "$SERVER_ROOT/dl"

# Fake "binary" — just a shell script that prints a version
make_fake_bin() {
  ver="$1"; out="$2"
  cat > "$out" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version|-v|version) echo "unblock $ver" ;;
  *) echo "fake unblock binary ($ver)"; exit 0 ;;
esac
EOF
  chmod +x "$out"
}

# Fake "binary" that dies the way a real broken artifact dies: no output at
# all, only an exit status. `kill` on its own pid reproduces a genuine signal
# death (rc = 128+signal), which is what install.sh must classify.
make_dead_bin() {
  mode="$1"; out="$2"
  case "$mode" in
    sigkill) body='kill -9 $$' ;;          # 137 — unsigned arm64 signature
    sigtrap) body='kill -s TRAP $$' ;;     # 133 — hardened runtime, no JIT ent
    silent)  body='exit 0' ;;              # rc=0 but says nothing: false green
    hang)    body='sleep 120' ;;           # never returns
    *) echo "bad mode $mode"; exit 1 ;;
  esac
  cat > "$out" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$out"
}

publish_release() {
  tag="$1"; os="$2"; arch="$3"
  asset="unblock-${os}-${arch}"
  # Pointer metadata (the primary source) carries the REAL tag; the API mock
  # carries a decoy so a precedence bug (API consulted first) shows up in the
  # log instead of being masked by identical bodies.
  printf '{"tag_name":"%s","name":"%s"}\n' "$tag" "$tag" > "$SERVER_ROOT/api/pointer.json"
  printf '{"tag_name":"%s","name":"%s"}\n' "v9.9.9-apionly" "v9.9.9-apionly" > "$SERVER_ROOT/api/latest.json"
  # Asset
  make_fake_bin "$tag" "$SERVER_ROOT/dl/$asset"
  publish_sums "$asset"
}

# Same release, but the asset is a binary that cannot run.
publish_dead_release() {
  tag="$1"; os="$2"; arch="$3"; mode="$4"
  asset="unblock-${os}-${arch}"
  printf '{"tag_name":"%s","name":"%s"}\n' "$tag" "$tag" > "$SERVER_ROOT/api/pointer.json"
  printf '{"tag_name":"%s","name":"%s"}\n' "v9.9.9-apionly" "v9.9.9-apionly" > "$SERVER_ROOT/api/latest.json"
  make_dead_bin "$mode" "$SERVER_ROOT/dl/$asset"
  publish_sums "$asset"
}

publish_sums() {
  asset="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$SERVER_ROOT/dl" && sha256sum "$asset") > "$SERVER_ROOT/dl/SHA256SUMS"
  else
    (cd "$SERVER_ROOT/dl" && shasum -a 256 "$asset") > "$SERVER_ROOT/dl/SHA256SUMS"
  fi
}

start_server() {
  if command -v python3 >/dev/null 2>&1; then PY=python3
  elif command -v python  >/dev/null 2>&1; then PY=python
  else echo "skipping: no python for mock server"; exit 0; fi
  (cd "$SERVER_ROOT" && "$PY" -m http.server "$SERVER_PORT" >/dev/null 2>&1) &
  SERVER_PID=$!
  # Wait for boot
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf "http://127.0.0.1:$SERVER_PORT/api/latest.json" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "mock server failed to start"; exit 1
}

# Patch install.sh to point at our mock server. Both metadata sources (the
# install.kaeva.app pointer and the api.github.com fallback) serve the same
# JSON shape, so both map to the same mock endpoint here.
patched_install() {
  out="$1"
  sed \
    -e "s|https://install.kaeva.app/api/cli-latest|http://127.0.0.1:${SERVER_PORT}/api/pointer.json|g" \
    -e "s|https://api.github.com/repos/\${REPO}/releases/latest|http://127.0.0.1:${SERVER_PORT}/api/latest.json|g" \
    -e "s|https://github.com/\${REPO}/releases/download/\${remote_tag}|http://127.0.0.1:${SERVER_PORT}/dl|g" \
    "$INSTALL_SH" > "$out"
  chmod +x "$out"
}

# Variant: BOTH metadata sources dead (closed port 1 -> instant refusal,
# curl/wget treat connection-refused as fatal, no retry stall), assets live.
patched_meta_dead() {
  out="$1"
  sed \
    -e "s|https://install.kaeva.app/api/cli-latest|http://127.0.0.1:1/pointer|g" \
    -e "s|https://api.github.com/repos/\${REPO}/releases/latest|http://127.0.0.1:1/api|g" \
    -e "s|https://github.com/\${REPO}/releases/download/\${remote_tag}|http://127.0.0.1:${SERVER_PORT}/dl|g" \
    "$INSTALL_SH" > "$out"
  chmod +x "$out"
}

# Variant: pointer dead, API source live -> exercises the fallback leg.
patched_pointer_dead() {
  out="$1"
  sed \
    -e "s|https://install.kaeva.app/api/cli-latest|http://127.0.0.1:1/pointer|g" \
    -e "s|https://api.github.com/repos/\${REPO}/releases/latest|http://127.0.0.1:${SERVER_PORT}/api/latest.json|g" \
    -e "s|https://github.com/\${REPO}/releases/download/\${remote_tag}|http://127.0.0.1:${SERVER_PORT}/dl|g" \
    "$INSTALL_SH" > "$out"
  chmod +x "$out"
}

# ---------- detect host os/arch the way install.sh does ----------
detect() {
  case "$(uname -s)" in Linux*) echo -n "linux-";; Darwin*) echo -n "darwin-";; *) echo "skip-host"; return;; esac
  case "$(uname -m)" in x86_64|amd64) echo "x64";; arm64|aarch64) echo "arm64";; *) echo "skip-arch";; esac
}

HOST_PLAT="$(detect)"
case "$HOST_PLAT" in
  skip-*|*-skip-*) echo "skipping: host platform not supported by installer ($HOST_PLAT)"; exit 0 ;;
esac
OS="${HOST_PLAT%-*}"; ARCH="${HOST_PLAT#*-}"

publish_release "v0.2.0" "$OS" "$ARCH"
start_server

PATCHED="$TESTDIR/install_patched.sh"
patched_install "$PATCHED"

# ---------- test 1: fresh install ----------
echo "test 1: fresh install"
FAKE_HOME="$TESTDIR/home1"
mkdir -p "$FAKE_HOME"
set +e
HOME="$FAKE_HOME" PATH="$FAKE_HOME/.local/bin:/usr/bin:/bin" "$INSTALL_SHELL" "$PATCHED" > "$TESTDIR/t1.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -x "$FAKE_HOME/.local/bin/unblock" ] \
   && grep -q "latest release: v0.2.0" "$TESTDIR/t1.log" \
   && grep -q "verified: it executes and reports" "$TESTDIR/t1.log"; then
  ok "installs binary, rc=0, tag came from the POINTER (not the API decoy), and the post-install execution check RAN and passed"
else
  fail "rc=$RC, binary exists=$( [ -x "$FAKE_HOME/.local/bin/unblock" ] && echo yes || echo no ) — log:"
  cat "$TESTDIR/t1.log" | sed 's/^/    /'
fi

# ---------- test 2: idempotency (same version) ----------
echo "test 2: idempotency"
set +e
HOME="$FAKE_HOME" PATH="$FAKE_HOME/.local/bin:/usr/bin:/bin" "$INSTALL_SHELL" "$PATCHED" > "$TESTDIR/t2.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 2 ]; then
  ok "second run exits 2 (already installed)"
else
  fail "expected rc=2, got rc=$RC — log:"
  cat "$TESTDIR/t2.log" | sed 's/^/    /'
fi

# ---------- test 3: bad checksum ----------
echo "test 3: bad checksum"
# Corrupt the SHA256SUMS file
echo "deadbeef00000000000000000000000000000000000000000000000000000000  unblock-${OS}-${ARCH}" > "$SERVER_ROOT/dl/SHA256SUMS"
FAKE_HOME3="$TESTDIR/home3"
mkdir -p "$FAKE_HOME3"
set +e
HOME="$FAKE_HOME3" PATH="$FAKE_HOME3/.local/bin:/usr/bin:/bin" "$INSTALL_SHELL" "$PATCHED" > "$TESTDIR/t3.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -q 'sha256 mismatch' "$TESTDIR/t3.log"; then
  ok "bad checksum exits 1 with mismatch message"
else
  fail "expected rc=1 + 'sha256 mismatch', got rc=$RC — log:"
  cat "$TESTDIR/t3.log" | sed 's/^/    /'
fi

# ---------- test 4: install path detection per OS ----------
echo "test 4: install path"
case "$OS" in
  linux|darwin)
    if [ -x "$FAKE_HOME/.local/bin/unblock" ]; then
      ok "installed to \$HOME/.local/bin/unblock"
    else
      fail "expected \$HOME/.local/bin/unblock to exist"
    fi
    ;;
esac

# Restore a clean release: test 3 corrupted the served SHA256SUMS.
publish_release "v0.2.0" "$OS" "$ARCH"

# ---------- test 5: UNBLOCK_VERSION pin, metadata sources DOWN ----------
echo "test 5: UNBLOCK_VERSION pin survives dead metadata sources"
PATCHED_META_DEAD="$TESTDIR/install_meta_dead.sh"
patched_meta_dead "$PATCHED_META_DEAD"
FAKE_HOME5="$TESTDIR/home5"
mkdir -p "$FAKE_HOME5"
set +e
HOME="$FAKE_HOME5" PATH="$FAKE_HOME5/.local/bin:/usr/bin:/bin" UNBLOCK_VERSION=v0.2.0 \
  "$INSTALL_SHELL" "$PATCHED_META_DEAD" > "$TESTDIR/t5.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -x "$FAKE_HOME5/.local/bin/unblock" ]; then
  ok "pinned install succeeds with every metadata endpoint dead"
else
  fail "expected rc=0 + binary, got rc=$RC — log:"
  cat "$TESTDIR/t5.log" | sed 's/^/    /'
fi

# ---------- test 6: pointer down -> API-source fallback ----------
echo "test 6: pointer outage falls back to the API source"
PATCHED_PTR_DEAD="$TESTDIR/install_pointer_dead.sh"
patched_pointer_dead "$PATCHED_PTR_DEAD"
FAKE_HOME6="$TESTDIR/home6"
mkdir -p "$FAKE_HOME6"
set +e
HOME="$FAKE_HOME6" PATH="$FAKE_HOME6/.local/bin:/usr/bin:/bin" \
  "$INSTALL_SHELL" "$PATCHED_PTR_DEAD" > "$TESTDIR/t6.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -x "$FAKE_HOME6/.local/bin/unblock" ] \
   && grep -q "trying next source" "$TESTDIR/t6.log" \
   && grep -q "v9.9.9-apionly" "$TESTDIR/t6.log"; then
  ok "fallback source installs (decoy tag proves the API leg ran); failover stated"
else
  fail "expected rc=0 + binary + 'trying next source', got rc=$RC — log:"
  cat "$TESTDIR/t6.log" | sed 's/^/    /'
fi

# ---------- test 7: every metadata source down, no pin ----------
echo "test 7: all metadata sources down -> honest error + pin hint"
FAKE_HOME7="$TESTDIR/home7"
mkdir -p "$FAKE_HOME7"
set +e
HOME="$FAKE_HOME7" PATH="$FAKE_HOME7/.local/bin:/usr/bin:/bin" \
  "$INSTALL_SHELL" "$PATCHED_META_DEAD" > "$TESTDIR/t7.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -q "UNBLOCK_VERSION" "$TESTDIR/t7.log"; then
  ok "exit 1 and the error teaches the UNBLOCK_VERSION escape hatch"
else
  fail "expected rc=1 + UNBLOCK_VERSION hint, got rc=$RC — log:"
  cat "$TESTDIR/t7.log" | sed 's/^/    /'
fi

# ---------- issue #20: the binary must be proven to RUN ----------
# Helper: install a deliberately-broken artifact into a throwaway HOME and
# hand back the log path + rc via globals (POSIX sh has no return values).
DEAD_RC=0
DEAD_LOG=""
DEAD_HOME=""
run_dead_install() { # run_dead_install <mode> <name> [env-assignments...]
  mode="$1"; name="$2"; shift 2
  publish_dead_release "v0.2.0" "$OS" "$ARCH" "$mode"
  DEAD_HOME="$TESTDIR/home_$name"
  DEAD_LOG="$TESTDIR/$name.log"
  mkdir -p "$DEAD_HOME"
  # A pre-existing rc file: a failed install must NOT be wired into the shell.
  echo "# pre-existing" > "$DEAD_HOME/.profile"
  set +e
  env HOME="$DEAD_HOME" PATH="$DEAD_HOME/.local/bin:/usr/bin:/bin" "$@" \
    "$INSTALL_SHELL" "$PATCHED" > "$DEAD_LOG" 2>&1
  DEAD_RC=$?
  set -e
}

# ---------- test 8: SIGKILL (137) — the live unsigned-arm64 defect ----------
echo "test 8: binary is SIGKILLed (137) -> loud failure, not exit 0"
run_dead_install sigkill t8
if [ "$DEAD_RC" -eq 1 ] \
   && grep -q "POST-INSTALL VERIFICATION FAILED" "$DEAD_LOG" \
   && grep -q "exit code: 137" "$DEAD_LOG" \
   && grep -q "zero bytes" "$DEAD_LOG"; then
  ok "silent SIGKILL fails the install (rc=1) and names the exit code + empty output"
else
  fail "expected rc=1 + verification failure naming 137, got rc=$DEAD_RC — log:"
  cat "$DEAD_LOG" | sed 's/^/    /'
fi

# The cause text is platform-specific: only darwin+arm64 gets the unsigned
# story, because an unsigned x64 Mach-O runs fine (that was the control in #20).
echo "test 8b: 137 is diagnosed for THIS platform, not generically"
if [ "$OS" = "darwin" ] && [ "$ARCH" = "arm64" ]; then
  if grep -q "not code-signed" "$DEAD_LOG" && grep -q "codesign -s - --force" "$DEAD_LOG"; then
    ok "darwin-arm64: names the unsigned binary AND gives a working ad-hoc sign command"
  else
    fail "darwin-arm64 should blame the missing signature — log:"
    cat "$DEAD_LOG" | sed 's/^/    /'
  fi
else
  if grep -q "SIGKILLed (137)" "$DEAD_LOG" && ! grep -q "not code-signed" "$DEAD_LOG"; then
    ok "${OS}-${ARCH}: reports the SIGKILL without falsely blaming code signing"
  else
    fail "non-darwin-arm64 must not blame code signing — log:"
    cat "$DEAD_LOG" | sed 's/^/    /'
  fi
fi

# ---------- test 9: SIGTRAP (133) — the sibling failure mode ----------
# 137 and 133 are indistinguishable to the user (both silent) but need
# OPPOSITE fixes. Sending a user with an entitlements problem off to re-sign
# an already-signed binary is the specific failure this test exists to block.
echo "test 9: 133 is distinguished from 137"
run_dead_install sigtrap t9
if [ "$DEAD_RC" -eq 1 ] && grep -q "exit code: 133" "$DEAD_LOG"; then
  if [ "$OS" = "darwin" ]; then
    if grep -q "allow-jit" "$DEAD_LOG" && ! grep -q "not code-signed" "$DEAD_LOG"; then
      ok "133 blames the missing JIT entitlement and does NOT say the binary is unsigned"
    else
      fail "133 must name allow-jit and must not say 'not code-signed' — log:"
      cat "$DEAD_LOG" | sed 's/^/    /'
    fi
  else
    if ! grep -q "allow-jit" "$DEAD_LOG"; then
      ok "133 on ${OS} reports the signal without macOS entitlement advice"
    else
      fail "non-darwin must not give macOS entitlement advice — log:"
      cat "$DEAD_LOG" | sed 's/^/    /'
    fi
  fi
else
  fail "expected rc=1 + 'exit code: 133', got rc=$DEAD_RC — log:"
  cat "$DEAD_LOG" | sed 's/^/    /'
fi

# ---------- test 10: rc=0 with no output — the false green ----------
# The whole reason the check asserts BOTH conditions: a process killed before
# main() prints nothing, so "no error text on stdout" is not evidence of health.
echo "test 10: exits 0 but prints nothing -> still a failure"
run_dead_install silent t10
if [ "$DEAD_RC" -eq 1 ] && grep -q "zero bytes" "$DEAD_LOG"; then
  ok "rc=0 with empty output is rejected (rc=0 alone is not proof of life)"
else
  fail "expected rc=1 on a silent success, got rc=$DEAD_RC — log:"
  cat "$DEAD_LOG" | sed 's/^/    /'
fi

# ---------- test 11: a failed install stays out of the user's shell ----------
echo "test 11: failed verification leaves rc files alone"
if ! grep -q "added by unblock-install" "$DEAD_HOME/.profile"; then
  ok "no PATH line written to .profile when the binary does not run"
else
  fail "a broken install must not modify shell rc files"
fi

# ---------- test 12: the hang is capped, and not misreported as 137 ----------
# The watchdog must not manufacture a 137: our own SIGKILL would otherwise be
# indistinguishable from the kernel's, i.e. the exact misdiagnosis this whole
# feature exists to prevent.
echo "test 12: a hung binary is capped and reported as a timeout, not a SIGKILL"
run_dead_install hang t12 UNBLOCK_VERIFY_TIMEOUT=3
if [ "$DEAD_RC" -eq 1 ] \
   && grep -q "exit code: 124" "$DEAD_LOG" \
   && ! grep -q "exit code: 137" "$DEAD_LOG"; then
  ok "hang -> rc=124 (timeout), never mislabelled as the kernel's SIGKILL"
else
  fail "expected rc=1 + 'exit code: 124', got rc=$DEAD_RC — log:"
  cat "$DEAD_LOG" | sed 's/^/    /'
fi

# ---------- test 13: the escape hatch works, and is loud ----------
echo "test 13: UNBLOCK_NO_VERIFY skips the check but says so"
run_dead_install sigkill t13 UNBLOCK_NO_VERIFY=1
if [ "$DEAD_RC" -eq 0 ] \
   && grep -q "UNBLOCK_NO_VERIFY set" "$DEAD_LOG" \
   && grep -q "has NOT been proven to run" "$DEAD_LOG"; then
  ok "opt-out installs the broken binary but warns it is unproven"
else
  fail "expected rc=0 + loud skip warning, got rc=$DEAD_RC — log:"
  cat "$DEAD_LOG" | sed 's/^/    /'
fi

# ---------- summary ----------
echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

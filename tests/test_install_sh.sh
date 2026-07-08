#!/usr/bin/env bash
# tests/test_install_sh.sh — integration tests for install.sh
#
# Strategy: mock the GitHub API + release asset with a tiny local HTTP server,
# point install.sh at it via env override, and assert:
#   - fresh install lands the binary at the expected path with +x
#   - second run with same version exits 2 (idempotency)
#   - bad sha256 in SHA256SUMS causes exit 1
#   - --version reports the mocked version (proxied through the fake binary)
#
# Runs in a temp $HOME so it never touches the real install.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL_SH="$ROOT/install.sh"

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

publish_release() {
  tag="$1"; os="$2"; arch="$3"
  asset="unblock-${os}-${arch}"
  # API metadata
  printf '{"tag_name":"%s","name":"%s"}\n' "$tag" "$tag" > "$SERVER_ROOT/api/latest.json"
  # Asset
  make_fake_bin "$tag" "$SERVER_ROOT/dl/$asset"
  # Checksum
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

# Patch install.sh to point at our mock server
patched_install() {
  out="$1"
  sed \
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
HOME="$FAKE_HOME" PATH="$FAKE_HOME/.local/bin:/usr/bin:/bin" bash "$PATCHED" > "$TESTDIR/t1.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -x "$FAKE_HOME/.local/bin/unblock" ]; then
  ok "installs binary, rc=0"
else
  fail "rc=$RC, binary exists=$( [ -x "$FAKE_HOME/.local/bin/unblock" ] && echo yes || echo no ) — log:"
  cat "$TESTDIR/t1.log" | sed 's/^/    /'
fi

# ---------- test 2: idempotency (same version) ----------
echo "test 2: idempotency"
set +e
HOME="$FAKE_HOME" PATH="$FAKE_HOME/.local/bin:/usr/bin:/bin" bash "$PATCHED" > "$TESTDIR/t2.log" 2>&1
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
HOME="$FAKE_HOME3" PATH="$FAKE_HOME3/.local/bin:/usr/bin:/bin" bash "$PATCHED" > "$TESTDIR/t3.log" 2>&1
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

# ---------- test 5: PATH persisted even with no pre-existing rc file ----------
# Regression guard for install.sh:137-143: on a fresh account / minimal
# container with none of .bashrc/.zshrc/.profile, the old loop was a silent
# no-op and `unblock` stayed "command not found" forever.
echo "test 5: PATH persistence with no pre-existing rc file (bash)"
publish_release "v0.3.0" "$OS" "$ARCH"   # test 3 corrupted the shared SHA256SUMS
FAKE_HOME5="$TESTDIR/home5"
mkdir -p "$FAKE_HOME5"
set +e
HOME="$FAKE_HOME5" SHELL=/bin/bash PATH="/usr/bin:/bin" bash "$PATCHED" > "$TESTDIR/t5.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -f "$FAKE_HOME5/.profile" ] && grep -q '\.local/bin' "$FAKE_HOME5/.profile"; then
  ok "creates ~/.profile and adds PATH when no rc file exists"
else
  fail "expected ~/.profile to be created with a PATH export — log:"
  cat "$TESTDIR/t5.log" | sed 's/^/    /'
fi

echo "test 5b: \$SHELL=zsh with no rc file gets ~/.zprofile instead"
FAKE_HOME5B="$TESTDIR/home5b"
mkdir -p "$FAKE_HOME5B"
set +e
HOME="$FAKE_HOME5B" SHELL=/bin/zsh PATH="/usr/bin:/bin" bash "$PATCHED" > "$TESTDIR/t5b.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] && [ -f "$FAKE_HOME5B/.zprofile" ]; then
  ok "creates ~/.zprofile for \$SHELL=zsh when no rc file exists"
else
  fail "expected ~/.zprofile to be created — log:"
  cat "$TESTDIR/t5b.log" | sed 's/^/    /'
fi

# ---------- test 6: version parse tolerates a build suffix ----------
# Regression guard for install.sh:120: "unblock 0.2.0 (build abc123)" used
# to parse (via `awk '{print $NF}'`) as "abc123)", which never matches the
# remote tag -- breaking idempotency and re-downloading/reinstalling on
# every single run.
echo "test 6: version string with build suffix doesn't break idempotency"
FAKE_HOME6="$TESTDIR/home6"
mkdir -p "$FAKE_HOME6/.local/bin"
cat > "$FAKE_HOME6/.local/bin/unblock" <<'FAKEBIN'
#!/usr/bin/env bash
case "$1" in
  --version|-v|version) echo "unblock 0.3.0 (build abc123)" ;;
  *) echo "fake unblock binary"; exit 0 ;;
esac
FAKEBIN
chmod +x "$FAKE_HOME6/.local/bin/unblock"
# Server is advertising v0.3.0 as latest at this point (test 5 republished it
# to replace the SHA256SUMS that test 3 deliberately corrupted) -- matches
# the fake bin's declared version above.
set +e
HOME="$FAKE_HOME6" PATH="$FAKE_HOME6/.local/bin:/usr/bin:/bin" bash "$PATCHED" > "$TESTDIR/t6.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 2 ]; then
  ok "version with build suffix still recognized as up-to-date (exit 2, not reinstalled)"
else
  fail "expected rc=2 (idempotent skip); a fragile version parse re-downloads every run. got rc=$RC — log:"
  cat "$TESTDIR/t6.log" | sed 's/^/    /'
fi

# ---------- test 7: GitHub API rate limit -> actionable message ----------
# Regression guard for install.sh:88: a rate-limited api.github.com response
# must produce a specific, actionable message instead of the misleading
# generic "could not parse tag_name from release metadata".
echo "test 7: rate-limited release metadata -> actionable message"
cat > "$SERVER_ROOT/api/latest.json" <<'RATELIMIT'
{"message":"API rate limit exceeded for 127.0.0.1.","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}
RATELIMIT
FAKE_HOME7="$TESTDIR/home7"
mkdir -p "$FAKE_HOME7"
set +e
HOME="$FAKE_HOME7" PATH="/usr/bin:/bin" bash "$PATCHED" > "$TESTDIR/t7.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -qi 'rate limit exceeded' "$TESTDIR/t7.log" && ! grep -q 'could not parse tag_name' "$TESTDIR/t7.log"; then
  ok "rate-limited metadata fetch prints an actionable message (not the generic parse error)"
else
  fail "expected rc=1 + actionable rate-limit message — log:"
  cat "$TESTDIR/t7.log" | sed 's/^/    /'
fi

# ---------- test 8: connect-timeout bounds a stalled connection ----------
# Regression guard for install.sh:52-56: no connect/max-time timeout meant a
# GitHub connection that accepts-then-stalls froze the piped installer
# forever with no feedback. 192.0.2.1 (RFC 5737 TEST-NET-1) is guaranteed
# non-routable, so a connection to it reliably stalls at the TCP layer.
echo "test 8: connect-timeout bounds a stalled connection (used to hang forever)"
BLACKHOLE_PATCHED="$TESTDIR/install_blackhole.sh"
sed -e "s|https://api.github.com/repos/\${REPO}/releases/latest|http://192.0.2.1:9/api/latest.json|g" \
  "$INSTALL_SH" > "$BLACKHOLE_PATCHED"
chmod +x "$BLACKHOLE_PATCHED"
FAKE_HOME8="$TESTDIR/home8"
mkdir -p "$FAKE_HOME8"
START_TS=$(date +%s)
HOME="$FAKE_HOME8" PATH="/usr/bin:/bin" bash "$BLACKHOLE_PATCHED" > "$TESTDIR/t8.log" 2>&1 &
BGPID=$!
# Pre-fix this hung forever. Post-fix, the shipped flags
# (--connect-timeout 10 --retry 3 --retry-delay 1) bound the worst case to
# ~43s observed; budget generously above that without waiting "forever".
BUDGET=75
WAITED=0
while kill -0 "$BGPID" 2>/dev/null && [ "$WAITED" -lt "$BUDGET" ]; do
  sleep 1
  WAITED=$((WAITED + 1))
done
if kill -0 "$BGPID" 2>/dev/null; then
  kill -9 "$BGPID" 2>/dev/null
  wait "$BGPID" 2>/dev/null
  fail "download hung past ${BUDGET}s against a stalled connection (no timeout enforced)"
else
  set +e
  wait "$BGPID"
  RC=$?
  set -e
  END_TS=$(date +%s)
  ELAPSED=$((END_TS - START_TS))
  if [ "$RC" -eq 1 ]; then
    ok "stalled connection fails within ${ELAPSED}s (bounded, not an infinite hang)"
  else
    fail "expected rc=1 within budget, got rc=$RC after ${ELAPSED}s — log:"
    cat "$TESTDIR/t8.log" | sed 's/^/    /'
  fi
fi

# ---------- summary ----------
echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

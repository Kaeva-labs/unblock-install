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
   && grep -q "latest release: v0.2.0" "$TESTDIR/t1.log"; then
  ok "installs binary, rc=0, tag came from the POINTER (not the API decoy)"
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

# ---------- summary ----------
echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

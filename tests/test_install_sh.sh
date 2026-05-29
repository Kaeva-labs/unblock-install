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

# ---------- test 5: cosign warn-skip paths ----------
# We never publish a SHA256SUMS.cosign.bundle in this mock server, so the
# installer should always take the "no cosign bundle in release" warn-skip
# path when cosign IS on PATH, and the "cosign not on PATH" warn-skip when
# it is NOT. Either way the install succeeds. This guards against the
# silent-abort regression: if cosign integration is wired wrong, install
# would fail closed even though there's nothing to verify against.
echo "test 5: cosign skip paths (release has no bundle)"
# Reset the SHA256SUMS to a valid one (test 3 corrupted it)
publish_release "v0.2.0" "$OS" "$ARCH"
FAKE_HOME5="$TESTDIR/home5"
mkdir -p "$FAKE_HOME5"

# Path 5a: cosign NOT on PATH (default for the test runner box)
set +e
HOME="$FAKE_HOME5" PATH="$FAKE_HOME5/.local/bin:/usr/bin:/bin" bash "$PATCHED" > "$TESTDIR/t5a.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -q 'cosign not on PATH' "$TESTDIR/t5a.log"; then
  ok "cosign-absent: install succeeds + emits warn-skip log"
else
  fail "5a: expected rc=0 + 'cosign not on PATH' warn, got rc=$RC — log:"
  cat "$TESTDIR/t5a.log" | sed 's/^/    /'
fi

# Path 5b: cosign IS on PATH but bundle is 404 (mock server doesn't serve it).
# Fake cosign that always succeeds. (If install.sh ever calls cosign in this
# path it's a wiring bug, since bundle download should fail before verify.)
FAKE_COSIGN_DIR="$TESTDIR/bin5b"; mkdir -p "$FAKE_COSIGN_DIR"
cat > "$FAKE_COSIGN_DIR/cosign" <<'EOF'
#!/usr/bin/env bash
echo "fake-cosign should not be called when bundle is absent" >&2
exit 0
EOF
chmod +x "$FAKE_COSIGN_DIR/cosign"
FAKE_HOME5B="$TESTDIR/home5b"; mkdir -p "$FAKE_HOME5B"
set +e
HOME="$FAKE_HOME5B" PATH="$FAKE_COSIGN_DIR:$FAKE_HOME5B/.local/bin:/usr/bin:/bin" \
  bash "$PATCHED" > "$TESTDIR/t5b.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -q 'no cosign bundle in release' "$TESTDIR/t5b.log"; then
  ok "cosign-present + bundle-absent: install succeeds + warn-skip on missing bundle"
else
  fail "5b: expected rc=0 + 'no cosign bundle' warn, got rc=$RC — log:"
  cat "$TESTDIR/t5b.log" | sed 's/^/    /'
fi

# ---------- test 6: cosign fails → abort ----------
# Publish a fake bundle so the install.sh download succeeds, then make
# cosign fail. Install must exit 1 with the abort message.
echo "test 6: cosign verify fails → abort"
echo "fake-bundle-bytes" > "$SERVER_ROOT/dl/SHA256SUMS.cosign.bundle"
FAIL_COSIGN_DIR="$TESTDIR/bin6"; mkdir -p "$FAIL_COSIGN_DIR"
cat > "$FAIL_COSIGN_DIR/cosign" <<'EOF'
#!/usr/bin/env bash
# Match the install.sh invocation arglist (verify-blob ...).
echo "cosign: simulated bad signature" >&2
exit 1
EOF
chmod +x "$FAIL_COSIGN_DIR/cosign"
FAKE_HOME6="$TESTDIR/home6"; mkdir -p "$FAKE_HOME6"
set +e
HOME="$FAKE_HOME6" PATH="$FAIL_COSIGN_DIR:$FAKE_HOME6/.local/bin:/usr/bin:/bin" \
  bash "$PATCHED" > "$TESTDIR/t6.log" 2>&1
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -q 'cosign signature verification FAILED' "$TESTDIR/t6.log"; then
  ok "cosign verify fails → install aborts (rc=1) with explicit message"
else
  fail "6: expected rc=1 + 'cosign signature verification FAILED', got rc=$RC — log:"
  cat "$TESTDIR/t6.log" | sed 's/^/    /'
fi

# ---------- summary ----------
echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# gate.sh — acceptance gate for Kaeva-labs/unblock-install (unblock-repo-gate entrypoint).
#
# Invoked by the repo-gate runner as `pnpm run gate` (GATE_KIND=pnpm-script) on
# every push to main, and runnable locally the same way. Runs ALL legs and
# fails at the end so a red gate reports every failure, not just the first.
#
# Gate-image constraint: bash + node are guaranteed; PowerShell is NOT.
# The install.ps1 legs therefore split into (a) node-side static contract
# checks that always run, and (b) a full parse + suite behind a pwsh guard
# that SKIPS LOUDLY when pwsh is absent (never silently).

set -u

FAILURES=0
leg() { # leg <name> <cmd...>
  local name="$1"; shift
  echo "── gate leg: ${name}"
  if "$@"; then
    echo "── PASS: ${name}"
  else
    echo "── FAIL: ${name} (exit $?)" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# 1. install.sh syntax
leg "install.sh bash -n" bash -n install.sh

# 1b. POSIX check — the public entrypoint is `curl | sh` (dash on Debian/
# Ubuntu); bash -n alone does not catch bashisms. LOUD skip when absent;
# the integration suite (leg below) also RUNS the installer under sh, which
# covers dash wherever sh IS dash (the ubuntu CI image).
if command -v dash >/dev/null 2>&1; then
  leg "install.sh dash -n (POSIX entrypoint)" dash -n install.sh
else
  echo "── ⚠️  SKIPPED (LOUD): install.sh dash -n — no dash on this runner."
fi

# 2. install.ps1 static contracts (node — always runs, even without pwsh)
leg "install.ps1 static contracts (node)" node -e '
  const fs = require("fs");
  const s = fs.readFileSync("install.ps1", "utf8");
  const must = (cond, msg) => { if (!cond) { console.error("contract FAIL: " + msg); process.exit(1); } };
  must(s.startsWith("# install.ps1"), "first bytes must be \"# install.ps1\" (serving contract)");
  must(/[$]Repo[ ]*=[ ]*[\x27]Kaeva-labs[/]unblock-install[\x27]/.test(s), "release source must be Kaeva-labs/unblock-install");
  must(!s.includes("\u0000"), "no NUL bytes");
  must(s.includes("function Invoke-Install"), "Invoke-Install present");
'

# 3. install.ps1 full parse + suite (pwsh only — LOUD skip otherwise)
PS_CHECK='
  $f = Join-Path (Get-Location) "install.ps1"
  $errs = $null; $tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs) | Out-Null
  if ($errs.Count -ne 0) { $errs | ForEach-Object { Write-Error $_.Message }; exit 1 }
  & ./tests/Test-InstallPs1.ps1
  exit $LASTEXITCODE
'
if command -v pwsh >/dev/null 2>&1; then
  leg "install.ps1 parse + Test-InstallPs1.ps1 (pwsh)" pwsh -NoProfile -Command "$PS_CHECK"
elif command -v powershell >/dev/null 2>&1; then
  leg "install.ps1 parse + Test-InstallPs1.ps1 (powershell 5.1)" powershell -NoProfile -Command "$PS_CHECK"
else
  echo "── ⚠️  SKIPPED (LOUD): install.ps1 full parse + suite — no pwsh/powershell on this runner."
  echo "──     The node static-contract leg above still ran. Adding pwsh to the gate image"
  echo "──     is filed with unblock_ci; until then Windows-side coverage runs on dev boxes only."
fi

# 4-6b. node suites (pure node, no network, no CF runtime)
leg "desktop asset matcher suite" node tests/test_desktop_api.mjs
leg "feed schema + sig-verify suite" node tests/test_feed.mjs
leg "waitlist handler suite" node tests/test_waitlist_api.mjs
leg "cli-latest release-pointer suite" node tests/test_cli_latest.mjs

# 7. install.sh integration suite (mock server, temp HOME)
leg "install.sh integration suite" bash tests/test_install_sh.sh

# 8. Stale-org-slug guard — the exact regression found live 2026-07-25:
#    main still pinned Viraj0518/unblock-install while releases live under
#    Kaeva-labs. Any reappearance anywhere in the tree is a red.
leg "no stale Viraj0518 slug in tracked files" bash -c '
  # git grep scans the TRACKED tree only — local build artifacts (.wrangler/tmp
  # dev bundles from the pre-transfer era) must not red the gate, and the gate
  # runner clones fresh anyway. ":!gate.sh" excludes this guard itself.
  hits=$(git grep -Il "Viraj0518" -- . ":!gate.sh" 2>/dev/null || true)
  if [ -n "$hits" ]; then echo "stale slug found in:"; echo "$hits"; exit 1; fi
'

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "GATE RED: ${FAILURES} leg(s) failed."
  exit 1
fi
echo "GATE GREEN: all legs passed (PS suite loud-skipped if noted above)."
exit 0

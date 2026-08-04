# install.ps1 -- UNBLOCK CLI installer for Windows (PowerShell 5.1+)
#
# Usage:
#   iwr -useb install.kaeva.app | iex
#
# Env knobs (all optional):
#   UNBLOCK_VERSION=vX.Y.Z    pin the version to install -- skips ALL release-
#                             metadata resolution (GitHub-API-independent)
#   UNBLOCK_INSTALL_DIR=DIR   install target (default %LOCALAPPDATA%\unblock)
#   UNBLOCK_NO_MODIFY_PATH=1  never touch the persistent USER PATH
#   UNBLOCK_LATEST_URL=URL    override the release-pointer endpoint
#
# What it does (idempotent):
#   1. Detect arch (x64/arm64)
#   2. Resolve the version: UNBLOCK_VERSION pin, else the CF-edge-cached
#      pointer at install.kaeva.app/api/cli-latest, else api.github.com
#   3. If `unblock` is already on PATH and version >= that, exit 2 (skip);
#      otherwise download the release artifact from
#      github.com/Kaeva-labs/unblock-install/releases/latest
#   4. Verify SHA256 against SHA256SUMS published alongside the release
#   5. Install to $env:LOCALAPPDATA\unblock\unblock.exe, prepend to USER PATH
#   6. Print onboarding hint
#
# Exit codes (via $LASTEXITCODE / exit):
#   0 success
#   1 failure
#   2 already installed (skipped — including a concurrent-install race loser
#     whose box already ended up with a satisfying binary)
#
# Signature verification: release artifacts are checked via SHA256
# checksums (see below) delivered over HTTPS to github.com. Cryptographic
# artifact signing is not yet implemented.

$ErrorActionPreference = 'Stop'

# ---------- config ----------
$Repo        = 'Kaeva-labs/unblock-install'
$BinName     = 'unblock.exe'
$InstallDir  = if ($env:UNBLOCK_INSTALL_DIR) { $env:UNBLOCK_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'unblock' }
$TmpDir      = Join-Path ([System.IO.Path]::GetTempPath()) ("unblock-install-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
$LockFile    = Join-Path $InstallDir '.unblock-install.lock'
$script:LockHeld = $false
$script:LockStream = $null

# Force TLS 1.2 for older PowerShell 5.1 hosts
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------- helpers ----------
function Write-Log  { param([string]$m) Write-Host "[unblock-install] $m" -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host "[unblock-install] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[unblock-install] $m" -ForegroundColor Red }

function Cleanup {
  if (Test-Path $TmpDir) { Remove-Item -Recurse -Force -Path $TmpDir -ErrorAction SilentlyContinue }
  if ($script:LockHeld) {
    try { $script:LockStream.Close() } catch {}
    Remove-Item -Force -Path $LockFile -ErrorAction SilentlyContinue
    $script:LockHeld = $false
  }
}

function Test-Command { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-Arch {
  $a = $env:PROCESSOR_ARCHITECTURE
  if ($env:PROCESSOR_ARCHITEW6432) { $a = $env:PROCESSOR_ARCHITEW6432 }
  switch ($a) {
    'AMD64' { return 'x64' }
    'ARM64' { return 'arm64' }
    'x86'   { return 'x64' }   # 32-bit shell on 64-bit OS -- best-effort
    default { Write-Err "unsupported arch: $a"; Cleanup; exit 1 }
  }
}

function Compare-Versions {
  # Returns -1, 0, 1 -- like cmp(a, b). Strips leading 'v'.
  param([string]$a, [string]$b)
  $aa = ($a -replace '^v','')
  $bb = ($b -replace '^v','')
  try {
    $va = [version]$aa
    $vb = [version]$bb
    return $va.CompareTo($vb)
  } catch {
    # Fallback: string compare
    return [string]::Compare($aa, $bb, $true)
  }
}

function Get-LatestTag {
  # Version pin: skips ALL metadata resolution, so the install works even
  # when every metadata source is down (asset downloads use the release
  # CDN, not the API). This is the stage/demo escape hatch.
  if ($env:UNBLOCK_VERSION) {
    # Normalize: accept 0.1.7 / v0.1.7 / V0.1.7, emit v0.1.7 (tags are vX.Y.Z).
    $v = 'v' + ($env:UNBLOCK_VERSION -replace '^[vV]', '')
    Write-Log "using pinned version $v (UNBLOCK_VERSION) -- skipping release metadata"
    return $v
  }

  # Primary: our own CF-fronted, edge-cached pointer -- not subject to
  # api.github.com's unauthenticated 60 req/hr/IP limit (shared across a
  # whole NAT), which 504-killed live installs on 2026-07-28.
  # Fallback: api.github.com direct -- same JSON shape, one parser, so a
  # pointer outage can never make an install worse than the old behavior.
  $pointerUrl = if ($env:UNBLOCK_LATEST_URL) { $env:UNBLOCK_LATEST_URL } else { 'https://install.kaeva.app/api/cli-latest' }
  $apiUrl     = "https://api.github.com/repos/$Repo/releases/latest"
  # Per-source budgets: the CF-edge pointer is fast-or-not-at-all (one try,
  # tight timeout -- a hanging pointer must never stall the install); the
  # flaky API source gets patience (retries + backoff).
  $sources = @(
    @{ Url = $pointerUrl; Attempts = 1; TimeoutSec = 8 },
    @{ Url = $apiUrl;     Attempts = 3; TimeoutSec = 30 }
  )
  foreach ($s in $sources) {
    for ($i = 1; $i -le $s.Attempts; $i++) {
      try {
        $json = Invoke-RestMethod -Uri $s.Url -UseBasicParsing -TimeoutSec $s.TimeoutSec -Headers @{ 'User-Agent' = 'unblock-install' }
        if ($json.tag_name) { return $json.tag_name }
        Write-Warn "no tag_name in metadata from $($s.Url) -- trying next source"
        break
      } catch {
        if ($i -lt $s.Attempts) {
          Write-Warn "metadata fetch failed ($($s.Url)) attempt $i/$($s.Attempts) -- retrying in $(2 * $i)s"
          Start-Sleep -Seconds (2 * $i)
        } else {
          Write-Warn "failed to fetch release metadata from $($s.Url): $($_.Exception.Message) -- trying next source"
        }
      }
    }
  }
  Write-Err 'could not resolve the latest release from any source:'
  Write-Err "  $pointerUrl"
  Write-Err "  $apiUrl"
  Write-Err 'if this is a network blip, re-run in a minute -- or pin a version and skip'
  Write-Err "resolution entirely (releases: github.com/$Repo/releases):"
  Write-Err '  $env:UNBLOCK_VERSION = "vX.Y.Z"; iwr -useb install.kaeva.app/install.ps1 | iex'
  Cleanup; exit 1
}

function Test-AlreadyInstalled {
  param([string]$RemoteTag)
  if (-not (Test-Command 'unblock')) { return $false }
  $cur = $null
  try { $cur = (& unblock --version 2>$null | Select-Object -First 1).Split(' ')[-1] } catch {}
  if ([string]::IsNullOrWhiteSpace($cur)) { return $false }
  $cmp = Compare-Versions -a $cur -b $RemoteTag
  if ($cmp -ge 0) {
    Write-Log "already installed: unblock $cur (>= remote $RemoteTag)"
    return $true
  }
  Write-Log "upgrading: $cur -> $RemoteTag"
  return $false
}

function Add-ToUserPath {
  param([string]$Dir)
  if ($env:UNBLOCK_NO_MODIFY_PATH) {
    # Patch this session only; the persistent USER PATH stays untouched.
    if (-not (($env:Path -split ';') -contains $Dir)) { $env:Path = "$Dir;$env:Path" }
    Write-Log "UNBLOCK_NO_MODIFY_PATH set -- USER PATH left untouched (this session only: $Dir)"
    return
  }
  $cur = [Environment]::GetEnvironmentVariable('Path','User')
  if ([string]::IsNullOrEmpty($cur)) { $cur = '' }
  $parts = $cur.Split(';') | Where-Object { $_ -ne '' }
  if ($parts -contains $Dir) {
    Write-Log "$Dir already in USER PATH"
    return
  }
  $new = if ($cur) { "$Dir;$cur" } else { $Dir }
  [Environment]::SetEnvironmentVariable('Path', $new, 'User')
  # Also patch current session
  $env:Path = "$Dir;$env:Path"
  Write-Log "added $Dir to USER PATH (open a new shell for it to take effect globally)"
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
}

function Test-InstalledAtPath {
  # Checks the binary AT the install path (not whatever PATH resolves — a race
  # loser's session PATH may not see the winner's fresh install).
  param([string]$Path, [string]$RemoteTag)
  if (-not (Test-Path $Path)) { return $false }
  $cur = $null
  try { $cur = (& $Path --version 2>$null | Select-Object -First 1).Split(' ')[-1] } catch {}
  if ([string]::IsNullOrWhiteSpace($cur)) { return $false }
  return ((Compare-Versions -a $cur -b $RemoteTag) -ge 0)
}

function Get-InstallLock {
  # A fleet-wide "upgrade now" can land N concurrent installer runs on one box
  # (seen live 2026-07-25: two runs raced one install dir; the loser failed
  # AFTER the winner had already placed the right binary, misreporting a
  # healthy box as a failed install). NOTE: New-Item -ItemType Directory is
  # NOT atomic (the cmdlet exists-checks, then calls the idempotent
  # Directory.CreateDirectory -- two processes can both "create" it; proven
  # by a live 7ms race). FileMode::CreateNew IS atomic at the OS level, and
  # holding the handle (FileShare::None) means a LIVE holder also defeats
  # stale-reclaim deletion; only a dead holder's lock can be removed.
  for ($try = 1; $try -le 60; $try++) {
    try {
      $script:LockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      $script:LockHeld = $true
      return $true
    } catch [System.IO.IOException] {
      # Distinguish a LIVE holder (its open FileShare::None handle makes our
      # probe fail with a sharing violation -> keep waiting) from a DEAD one
      # (handle gone -> probe opens -> the lock is stale NOW, no age wait).
      $holderAlive = $false
      try {
        $probe = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $probe.Close()
      } catch [System.IO.FileNotFoundException] {
        continue
      } catch [System.IO.IOException] {
        $holderAlive = $true
      }
      if (-not $holderAlive) {
        Write-Warn "removing stale install lock (holder no longer running): $LockFile"
        Remove-Item -Force -Path $LockFile -ErrorAction SilentlyContinue
        continue
      }
      Write-Log "another install is running (lock $LockFile) -- waiting 5s ($try/60)"
      Start-Sleep -Seconds 5
    }
  }
  return $false
}

# ---------- main ----------
function Invoke-Install {
  $arch = Get-Arch
  Write-Log "detected: windows-$arch"

  $remoteTag = Get-LatestTag
  Write-Log "latest release: $remoteTag"

  if (Test-AlreadyInstalled -RemoteTag $remoteTag) {
    Write-Log "nothing to do -- exit 2 (already installed, skipped)"
    Cleanup; exit 2
  }

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $installPath = Join-Path $InstallDir $BinName
  if (-not (Get-InstallLock)) {
    if (Test-InstalledAtPath -Path $installPath -RemoteTag $remoteTag) {
      Write-Log "install lock never freed, but $installPath already satisfies $remoteTag -- already installed (exit 2)"
      Cleanup; exit 2
    }
    Write-Err "another install has held the lock for 5+ minutes and no satisfying binary appeared ($LockFile)."
    Write-Err "it may be on a very slow download -- rerun once it completes, or remove the lock file if nothing is running."
    Cleanup; exit 1
  }
  # Another run may have finished while we waited on the lock.
  if (Test-InstalledAtPath -Path $installPath -RemoteTag $remoteTag) {
    Write-Log "a concurrent install already placed $BinName >= $remoteTag -- nothing to do (exit 2)"
    Cleanup; exit 2
  }

  # Asset naming: unblock-windows-<arch>.exe; SHA256SUMS in same release
  $asset    = "unblock-windows-$arch.exe"
  $baseUrl  = "https://github.com/$Repo/releases/download/$remoteTag"
  $assetUrl = "$baseUrl/$asset"
  $sumsUrl  = "$baseUrl/SHA256SUMS"

  $assetPath = Join-Path $TmpDir $asset
  $sumsPath  = Join-Path $TmpDir 'SHA256SUMS'

  Write-Log "downloading $assetUrl"
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $assetUrl -OutFile $assetPath -Headers @{ 'User-Agent' = 'unblock-install' }
  } catch {
    Write-Err "failed to download $assetUrl"
    Write-Err "no windows-$arch binary in release $remoteTag."
    Write-Err "see published assets: https://github.com/$Repo/releases/$remoteTag"
    Cleanup; exit 1
  }

  Write-Log 'downloading SHA256SUMS'
  $sumsOk = $true
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $sumsUrl -OutFile $sumsPath -Headers @{ 'User-Agent' = 'unblock-install' }
  } catch {
    Write-Warn 'SHA256SUMS not found in release -- skipping checksum verify'
    $sumsOk = $false
  }

  if ($sumsOk) {
    $expected = $null
    foreach ($line in Get-Content $sumsPath) {
      $parts = $line -split '\s+', 2
      # TrimStart('*') tolerates sha256sum binary-mode lines: "<hash> *name"
      if ($parts.Count -eq 2 -and $parts[1].Trim().TrimStart('*') -eq $asset) {
        $expected = $parts[0].ToLower()
        break
      }
    }
    if (-not $expected) {
      Write-Warn "no checksum entry for $asset in SHA256SUMS -- skipping verify"
    } else {
      $actual = Get-Sha256 -Path $assetPath
      if ($expected -ne $actual) {
        Write-Err "sha256 mismatch! expected=$expected actual=$actual"
        Cleanup; exit 1
      }
      Write-Log 'sha256 verified'
    }
  }

  # The target can be mid-execution or transiently locked -- retry briefly,
  # then tell the truth: a failed swap over an already-satisfying binary is
  # the exit-2 case, never a false red on a healthy box.
  $swapped = $false
  foreach ($attempt in 1..3) {
    try {
      Move-Item -Force -Path $assetPath -Destination $installPath -ErrorAction Stop
      $swapped = $true
      break
    } catch {
      Write-Warn "binary swap failed (attempt $attempt/3): $($_.Exception.Message) -- retrying in 2s"
      Start-Sleep -Seconds 2
    }
  }
  if (-not $swapped) {
    if (Test-InstalledAtPath -Path $installPath -RemoteTag $remoteTag) {
      Write-Log "swap failed but $installPath already satisfies $remoteTag (a concurrent install won) -- exit 2"
      Cleanup; exit 2
    }
    Write-Err "failed to install to $installPath after 3 attempts (binary in use?)"
    Cleanup; exit 1
  }
  Write-Log "installed to $installPath"

  Add-ToUserPath -Dir $InstallDir

  Write-Host ''
  Write-Host '------------------------------------------------------------'
  Write-Host "  unblock $remoteTag installed to $installPath"
  Write-Host ''
  Write-Host '  This PowerShell session can use unblock right now.'
  if ($env:UNBLOCK_NO_MODIFY_PATH) {
    Write-Host '  Other and new shells will NOT find it (UNBLOCK_NO_MODIFY_PATH is'
    Write-Host "  set): add $InstallDir to PATH yourself, or use the full path."
  } else {
    Write-Host '  New shells find it via your USER PATH; shells already open'
    Write-Host '  (including cmd and VS Code terminals) need a restart to see it.'
  }
  Write-Host ''
  Write-Host '  Now run:'
  Write-Host '    unblock login          # sign in -- or create your account'
  Write-Host '  then:'
  Write-Host '    unblock initialize     # connect to your org-brain'
  Write-Host ''
  Write-Host '  This installer only places the binary -- your ~/.unblock data'
  Write-Host '  (identity, comms, saved state) is untouched and safe to reinstall over.'
  Write-Host '------------------------------------------------------------'
  Cleanup
  exit 0
}

try {
  Invoke-Install
} catch {
  Write-Err "install failed: $_"
  Cleanup
  exit 1
}

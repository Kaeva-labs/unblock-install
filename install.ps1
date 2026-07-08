# install.ps1 -- UNBLOCK CLI installer for Windows (PowerShell 5.1+)
#
# Usage:
#   iwr -useb install.kaeva.app | iex
#
# What it does (idempotent):
#   1. Detect arch (x64/arm64)
#   2. If `unblock` is already on PATH and version >= remote latest, exit 2 (skip)
#   3. Download latest release artifact from
#      github.com/Viraj0518/unblock-install/releases/latest
#   4. Verify SHA256 against SHA256SUMS published alongside the release.
#      Verification is MANDATORY (fail-closed): a missing SHA256SUMS, a missing
#      entry for this asset, or a mismatch aborts the install with a nonzero
#      exit. Set $env:UNBLOCK_INSECURE_SKIP_CHECKSUM=1 to override the "cannot
#      verify" cases at your own risk (a genuine mismatch is never overridable).
#   5. Install to $env:LOCALAPPDATA\unblock\unblock.exe, prepend to USER PATH
#   6. Print onboarding hint
#
# Exit codes (via $LASTEXITCODE / exit):
#   0 success
#   1 failure
#   2 already installed (skipped)
#
# TODO(v2): cosign / Windows Authenticode signature verification.
#           For v1 we rely on SHA256 checksums + HTTPS to github.com.

$ErrorActionPreference = 'Stop'

# ---------- config ----------
$Repo        = 'Viraj0518/unblock-install'
$BinName     = 'unblock.exe'
$InstallDir  = if ($env:UNBLOCK_INSTALL_DIR) { $env:UNBLOCK_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'unblock' }
$TmpDir      = Join-Path ([System.IO.Path]::GetTempPath()) ("unblock-install-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

# Force TLS 1.2 for older PowerShell 5.1 hosts
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------- helpers ----------
function Write-Log  { param([string]$m) Write-Host "[unblock-install] $m" -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host "[unblock-install] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[unblock-install] $m" -ForegroundColor Red }

function Cleanup { if (Test-Path $TmpDir) { Remove-Item -Recurse -Force -Path $TmpDir -ErrorAction SilentlyContinue } }

function Test-Command { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-Arch {
  $a = $env:PROCESSOR_ARCHITECTURE
  if ($env:PROCESSOR_ARCHITEW6432) { $a = $env:PROCESSOR_ARCHITEW6432 }
  switch ($a) {
    'AMD64' { return 'x64' }
    'ARM64' { return 'arm64' }
    'x86'   { return 'x64' }   # 32-bit shell on 64-bit OS -- best-effort
    default { Write-Err "unsupported arch: $a"; exit 1 }
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
  $url = "https://api.github.com/repos/$Repo/releases/latest"
  Write-Log "fetching $url"
  try {
    $json = Invoke-RestMethod -Uri $url -UseBasicParsing -Headers @{ 'User-Agent' = 'unblock-install' }
  } catch {
    Write-Err "failed to fetch latest release metadata: $_"
    Cleanup; exit 1
  }
  if (-not $json.tag_name) {
    Write-Err 'no tag_name in release metadata'
    Cleanup; exit 1
  }
  return $json.tag_name
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
  # Integrity verification is FAIL-CLOSED: if a checksum cannot be obtained AND
  # matched, refuse to install. The only escape hatch is the explicit
  # UNBLOCK_INSECURE_SKIP_CHECKSUM=1 opt-out. A genuine hash mismatch is always
  # fatal and is never overridable -- it signals tampering, not absence.
  $verified = $false
  $verifyFailure = $null
  $sumsOk = $true
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $sumsUrl -OutFile $sumsPath -Headers @{ 'User-Agent' = 'unblock-install' }
  } catch {
    $sumsOk = $false
  }

  if (-not $sumsOk) {
    $verifyFailure = "failed to download SHA256SUMS from $sumsUrl"
  } else {
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
      $verifyFailure = "no checksum entry for $asset in SHA256SUMS (never expected for a well-formed release)"
    } else {
      $actual = Get-Sha256 -Path $assetPath
      if ($expected -ne $actual) {
        Write-Err "sha256 mismatch! expected=$expected actual=$actual"
        Cleanup; exit 1
      }
      Write-Log 'sha256 verified'
      $verified = $true
    }
  }

  if (-not $verified) {
    Write-Err $verifyFailure
    if ($env:UNBLOCK_INSECURE_SKIP_CHECKSUM -eq '1') {
      Write-Warn 'UNBLOCK_INSECURE_SKIP_CHECKSUM=1 set -- proceeding WITHOUT checksum verification (INSECURE)'
    } else {
      Write-Err 'refusing to install an unverified binary (checksum could not be obtained and matched).'
      Write-Err 'to override at your own risk, re-run with: $env:UNBLOCK_INSECURE_SKIP_CHECKSUM=1'
      Cleanup; exit 1
    }
  }

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $installPath = Join-Path $InstallDir $BinName
  Move-Item -Force -Path $assetPath -Destination $installPath
  Write-Log "installed to $installPath"

  Add-ToUserPath -Dir $InstallDir

  Write-Host ''
  Write-Host '------------------------------------------------------------'
  Write-Host "  unblock $remoteTag installed."
  Write-Host ''
  Write-Host '  Now run:'
  Write-Host '    unblock spawn <bin> --as <name> --role member'
  Write-Host '  (or:'
  Write-Host '    unblock login <invite-code> --persona <name> )'
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

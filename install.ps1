# install.ps1 -- UNBLOCK CLI installer for Windows (PowerShell 5.1+)
#
# Usage:
#   iwr -useb install.kaeva.app | iex
#
# What it does (idempotent):
#   1. Detect arch (x64/arm64)
#   2. If `unblock` is already on PATH and version >= remote latest, exit 2 (skip)
#   3. Download latest release artifact from
#      github.com/Viraj0518/unblock_cli/releases/latest
#   4. Verify SHA256 against SHA256SUMS published alongside the release
#   5. Install to $env:LOCALAPPDATA\unblock\unblock.exe, prepend to USER PATH
#   6. Print onboarding hint
#
# Exit codes (via $LASTEXITCODE / exit):
#   0 success
#   1 failure
#   2 already installed (skipped)
#
# Trust model:
#   1. HTTPS to github.com (CA-anchored).
#   2. SHA256 against SHA256SUMS published in the same release.
#   3. (optional) cosign keyless verification of SHA256SUMS when cosign is
#      on PATH AND the release contains SHA256SUMS.cosign.bundle. Missing
#      bundle == warn-and-skip (so the installer works against releases
#      that pre-date workflow signing). Failed verify == abort.

$ErrorActionPreference = 'Stop'

# ---------- config ----------
$Repo        = 'Viraj0518/unblock_cli'
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
    Write-Err 'no native binary release published yet?'
    Write-Err "fallback: install via npm -- npm i -g @unblock/cli@$($remoteTag.TrimStart('v'))"
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
      if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $asset) {
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

    # Optional: cosign keyless verification of SHA256SUMS. We only attempt
    # this when (a) cosign is on PATH and (b) the release ships a
    # SHA256SUMS.cosign.bundle. If either is missing we warn-and-skip,
    # since SHA256 over HTTPS is already a meaningful trust floor.
    # If cosign IS present and the bundle exists but verify fails, we
    # abort -- a failed signature is louder than a missing one.
    if (Test-Command 'cosign') {
      $bundleUrl  = "$baseUrl/SHA256SUMS.cosign.bundle"
      $bundlePath = Join-Path $TmpDir 'SHA256SUMS.cosign.bundle'
      $bundleOk = $true
      try {
        Invoke-WebRequest -UseBasicParsing -Uri $bundleUrl -OutFile $bundlePath -Headers @{ 'User-Agent' = 'unblock-install' } -ErrorAction Stop
      } catch {
        $bundleOk = $false
      }
      if ($bundleOk -and (Test-Path $bundlePath) -and ((Get-Item $bundlePath).Length -gt 0)) {
        # Cert identity = the workflow file that emitted the signature,
        # bound to a tag of the form v* (matches release.yml's on.tags).
        $certIdRe   = "^https://github.com/$Repo/.github/workflows/release.yml@refs/tags/v"
        $oidcIssuer = 'https://token.actions.githubusercontent.com'
        Write-Log 'verifying cosign keyless signature on SHA256SUMS'
        $verifyOk = $true
        try {
          & cosign verify-blob `
            --bundle $bundlePath `
            --certificate-identity-regexp $certIdRe `
            --certificate-oidc-issuer $oidcIssuer `
            $sumsPath *> $null
          if ($LASTEXITCODE -ne 0) { $verifyOk = $false }
        } catch {
          $verifyOk = $false
        }
        if ($verifyOk) {
          Write-Log "cosign verified: SHA256SUMS signed by $Repo/.github/workflows/release.yml (sigstore keyless)"
        } else {
          Write-Err 'cosign signature verification FAILED -- refusing to install'
          Write-Err "  bundle:   $bundleUrl"
          Write-Err "  identity: $certIdRe"
          Write-Err "  issuer:   $oidcIssuer"
          Cleanup; exit 1
        }
      } else {
        Write-Warn 'no cosign bundle in release (pre-signing release or CI did not run)'
        Write-Warn "  expected: $bundleUrl -- continuing on sha256-only trust"
      }
    } else {
      Write-Warn 'cosign not on PATH -- skipping signature verify (sha256 already verified)'
      Write-Warn '  install cosign for full keyless verify: https://docs.sigstore.dev/cosign/installation/'
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

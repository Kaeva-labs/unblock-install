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
#   4. Verify SHA256 against SHA256SUMS published alongside the release
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

# PS 5.1's Invoke-RestMethod/Invoke-WebRequest have no -MaximumRetryCount, so
# retry manually. Also gives every network call a bounded timeout instead of
# hanging forever on a stalled connection.
function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [int]$MaxAttempts = 3,
    [int]$DelaySeconds = 2,
    [string]$What = 'request',
    # Optional predicate run against the caught error; return $false to stop
    # retrying immediately (e.g. a confirmed rate-limit -- more attempts
    # can't succeed and just waste time).
    [scriptblock]$ShouldRetry = { $true }
  )
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      return & $Action
    } catch {
      $err = $_
      if ($attempt -ge $MaxAttempts -or -not (& $ShouldRetry $err)) { throw $err }
      Write-Warn "$What failed (attempt $attempt/$MaxAttempts) -- retrying in ${DelaySeconds}s"
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

# Best-effort classification of "was this failure a GitHub API rate limit?"
# so callers can fail fast (retrying a confirmed rate limit can't succeed)
# and print an actionable message instead of a generic one.
function Test-RateLimitError {
  param($ErrorRecord)
  $statusCode = $null
  try { $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode } catch {}
  $bodyText = "$($ErrorRecord.ErrorDetails.Message) $($ErrorRecord.Exception.Message)"
  return ($statusCode -eq 403 -or $bodyText -match 'rate limit')
}

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
    # api.github.com is rate-limited to 60 unauthenticated req/hr/IP. Behind a
    # shared corporate NAT or CI egress IP that limit gets hit intermittently.
    # Don't burn retries on a *confirmed* rate limit (more attempts can't
    # succeed) -- fail fast with an actionable message instead.
    $json = Invoke-WithRetry -What 'fetch latest release metadata' -ShouldRetry { param($e) -not (Test-RateLimitError $e) } -Action {
      Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'unblock-install' }
    }
  } catch {
    if (Test-RateLimitError $_) {
      Write-Err "GitHub API rate limit exceeded for this network's IP (60 req/hr, unauthenticated)."
      Write-Err 'This is usually transient on shared/corporate NAT or CI egress IPs -- wait a bit and retry.'
      Write-Err "You can also download a release directly: https://github.com/$Repo/releases/latest"
    } else {
      Write-Err "failed to fetch latest release metadata: $_"
    }
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
  try {
    # Extract a semver token rather than assuming it's the last whitespace
    # field -- output like "unblock 0.2.0 (build abc123)" would otherwise
    # parse as "abc123)" and break idempotency (never matches, so the
    # installer re-downloads and reinstalls on every run).
    $verLine = (& unblock --version 2>$null | Select-Object -First 1)
    if ($verLine -match '\d+\.\d+\.\d+') { $cur = $Matches[0] }
  } catch {}
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

  # [Environment]::GetEnvironmentVariable('Path','User') returns the
  # *expanded* string of a REG_EXPAND_SZ PATH, and SetEnvironmentVariable
  # writes it back as a static REG_SZ -- permanently freezing any dynamic
  # entries (e.g. %USERPROFILE%\bin, %JAVA_HOME%\bin) to their current
  # expansion. Read/write the raw registry value instead, preserving
  # whatever value kind (String vs ExpandString) it already had.
  $done = $false
  try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($key) {
      try {
        $opts = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        $curRaw = $key.GetValue('Path', '', $opts)
        if ($null -eq $curRaw) { $curRaw = '' }
        $kind = try { $key.GetValueKind('Path') } catch { [Microsoft.Win32.RegistryValueKind]::String }
        $parts = $curRaw.Split(';') | Where-Object { $_ -ne '' }
        if ($parts -contains $Dir) {
          Write-Log "$Dir already in USER PATH"
        } else {
          $newRaw = if ($curRaw) { "$Dir;$curRaw" } else { $Dir }
          $key.SetValue('Path', $newRaw, $kind)
          Write-Log "added $Dir to USER PATH (open a new shell for it to take effect globally)"
        }
        $done = $true
      } finally {
        $key.Close()
      }
    }
  } catch {
    $done = $false
  }

  if (-not $done) {
    # Fallback (e.g. registry access unavailable for some reason): same
    # behavior as before -- does not preserve %VAR% expansion, but still
    # gets the directory onto PATH rather than failing the install.
    $cur = [Environment]::GetEnvironmentVariable('Path','User')
    if ([string]::IsNullOrEmpty($cur)) { $cur = '' }
    $parts = $cur.Split(';') | Where-Object { $_ -ne '' }
    if ($parts -contains $Dir) {
      Write-Log "$Dir already in USER PATH"
    } else {
      $new = if ($cur) { "$Dir;$cur" } else { $Dir }
      [Environment]::SetEnvironmentVariable('Path', $new, 'User')
      Write-Log "added $Dir to USER PATH (open a new shell for it to take effect globally)"
    }
  }

  # Also patch current session
  $env:Path = "$Dir;$env:Path"
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
    Invoke-WithRetry -What "download $asset" -Action {
      Invoke-WebRequest -UseBasicParsing -Uri $assetUrl -OutFile $assetPath -TimeoutSec 120 -Headers @{ 'User-Agent' = 'unblock-install' }
    } | Out-Null
  } catch {
    Write-Err "failed to download $assetUrl"
    Write-Err "no windows-$arch binary in release $remoteTag."
    Write-Err "see published assets: https://github.com/$Repo/releases/$remoteTag"
    Cleanup; exit 1
  }

  Write-Log 'downloading SHA256SUMS'
  $sumsOk = $true
  try {
    Invoke-WithRetry -What 'download SHA256SUMS' -Action {
      Invoke-WebRequest -UseBasicParsing -Uri $sumsUrl -OutFile $sumsPath -TimeoutSec 120 -Headers @{ 'User-Agent' = 'unblock-install' }
    } | Out-Null
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

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $installPath = Join-Path $InstallDir $BinName
  $oldPath = "$installPath.old"

  # Windows locks a running executable, so Move-Item -Force straight onto an
  # in-use unblock.exe throws a sharing violation (likely here, since the
  # onboarding hint tells users to `unblock spawn` long-running agents).
  # Rename-then-replace instead: renaming an in-use exe IS allowed on
  # Windows even though overwriting/deleting it isn't.
  if (Test-Path $installPath) {
    if (Test-Path $oldPath) { Remove-Item -Force $oldPath -ErrorAction SilentlyContinue }
    try {
      Move-Item -Force -Path $installPath -Destination $oldPath -ErrorAction Stop
    } catch {
      Write-Err "could not replace the existing install at $installPath -- it looks like it's in use."
      Write-Err 'close any running unblock processes (e.g. unblock spawn agents) and re-run the installer.'
      Cleanup; exit 1
    }
  }
  Move-Item -Force -Path $assetPath -Destination $installPath
  Remove-Item -Force $oldPath -ErrorAction SilentlyContinue
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

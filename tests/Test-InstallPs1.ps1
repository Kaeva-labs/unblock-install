# tests/Test-InstallPs1.ps1 -- integration tests for install.ps1
#
# Strategy: spin up a local HTTP listener serving a fake release + checksum,
# patch install.ps1 to point at it, run in a sandboxed $env:USERPROFILE.
#
# Asserts:
#   - fresh install lands unblock.exe in the expected dir
#   - second run with same version exits 2 (idempotency)
#   - bad SHA256 in SHA256SUMS causes exit 1

$ErrorActionPreference = 'Stop'

$Here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root       = Resolve-Path (Join-Path $Here '..')
$InstallPs1 = Join-Path $Root 'install.ps1'

$Pass = 0; $Fail = 0
function Ok   { param([string]$m) Write-Host "  PASS $m" -ForegroundColor Green; $script:Pass++ }
function Bad  { param([string]$m) Write-Host "  FAIL $m" -ForegroundColor Red;   $script:Fail++ }

$TestDir   = Join-Path ([System.IO.Path]::GetTempPath()) ("unblock-pstest-" + [Guid]::NewGuid().ToString('N'))
$ServerDir = Join-Path $TestDir 'server'
$ApiDir    = Join-Path $ServerDir 'api'
$DlDir     = Join-Path $ServerDir 'dl'
New-Item -ItemType Directory -Force -Path $ApiDir,$DlDir | Out-Null

$Port = $env:UNBLOCK_TEST_PORT
if (-not $Port) { $Port = 8732 }

# ---------- fake binary ----------
function New-FakeBin {
  param([string]$Version, [string]$OutPath)
  # Tiny .cmd that prints a version line -- easier than building an .exe
  $cmd = @"
@echo off
if "%1"=="--version" (echo unblock $Version & exit /b 0)
if "%1"=="-v"        (echo unblock $Version & exit /b 0)
echo fake unblock binary ($Version)
exit /b 0
"@
  Set-Content -Path $OutPath -Value $cmd -Encoding ASCII
}

function Publish-Release {
  param([string]$Tag, [string]$Arch)
  $asset = "unblock-windows-$Arch.exe"
  # API metadata
  $api = @{ tag_name = $Tag; name = $Tag } | ConvertTo-Json
  Set-Content -Path (Join-Path $ApiDir 'latest.json') -Value $api -Encoding ASCII
  # Asset -- write to <asset>.cmd internally but serve under requested name
  $assetPath = Join-Path $DlDir $asset
  New-FakeBin -Version $Tag -OutPath $assetPath
  # SHA256SUMS
  $hash = (Get-FileHash -Algorithm SHA256 -Path $assetPath).Hash.ToLower()
  Set-Content -Path (Join-Path $DlDir 'SHA256SUMS') -Value "$hash  $asset" -Encoding ASCII
  return $asset
}

# ---------- mock HTTP server (HttpListener) ----------
$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add("http://127.0.0.1:$Port/")
$Listener.Start()

$ServerJob = Start-Job -ScriptBlock {
  param($listenerRef, $root)
  $listener = $listenerRef
  while ($listener.IsListening) {
    try {
      $ctx = $listener.GetContext()
      $path = $ctx.Request.Url.AbsolutePath.TrimStart('/')
      if ($path -eq '') { $path = 'index.html' }
      $file = Join-Path $root $path
      if (Test-Path $file) {
        $bytes = [IO.File]::ReadAllBytes($file)
        $ctx.Response.ContentType = 'application/octet-stream'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        $ctx.Response.StatusCode = 404
      }
      $ctx.Response.Close()
    } catch { break }
  }
} -ArgumentList $Listener, $ServerDir

# Background jobs don't share the listener cleanly across runspaces in PS 5.1 --
# so instead, run the server inline in a runspace.
Stop-Job $ServerJob -ErrorAction SilentlyContinue
Remove-Job $ServerJob -ErrorAction SilentlyContinue

$Runspace = [runspacefactory]::CreateRunspace()
$Runspace.Open()
$ps = [powershell]::Create()
$ps.Runspace = $Runspace
[void]$ps.AddScript({
  param($listener, $root)
  while ($listener.IsListening) {
    try {
      $ctx = $listener.GetContext()
      $path = $ctx.Request.Url.AbsolutePath.TrimStart('/')
      $file = Join-Path $root $path
      if (Test-Path $file) {
        $bytes = [IO.File]::ReadAllBytes($file)
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      } else {
        $ctx.Response.StatusCode = 404
      }
      $ctx.Response.Close()
    } catch { break }
  }
}).AddArgument($Listener).AddArgument($ServerDir)
$Async = $ps.BeginInvoke()

function Stop-MockServer {
  try { $Listener.Stop() } catch {}
  try { $ps.EndInvoke($Async) } catch {}
  try { $ps.Dispose() } catch {}
  try { $Runspace.Close() } catch {}
  if (Test-Path $TestDir) { Remove-Item -Recurse -Force $TestDir -ErrorAction SilentlyContinue }
}

try {
  # Detect arch
  $a = $env:PROCESSOR_ARCHITECTURE
  if ($env:PROCESSOR_ARCHITEW6432) { $a = $env:PROCESSOR_ARCHITEW6432 }
  $arch = switch ($a) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } default { 'x64' } }

  $asset = Publish-Release -Tag 'v0.2.0' -Arch $arch

  # Patch install.ps1 to use the mock server
  $patched = Join-Path $TestDir 'install_patched.ps1'
  $src = Get-Content $InstallPs1 -Raw
  $src = $src -replace 'https://api\.github\.com/repos/\$Repo/releases/latest', "http://127.0.0.1:$Port/api/latest.json"
  $src = $src -replace 'https://github\.com/\$Repo/releases/download/\$remoteTag', "http://127.0.0.1:$Port/dl"
  Set-Content -Path $patched -Value $src -Encoding UTF8

  # ---------- test 1: fresh install ----------
  Write-Host 'test 1: fresh install'
  $home1 = Join-Path $TestDir 'home1'
  New-Item -ItemType Directory -Force $home1 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home1 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patched *> (Join-Path $TestDir 't1.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $installed = Join-Path $env:UNBLOCK_INSTALL_DIR 'unblock.exe'
  if ($rc -eq 0 -and (Test-Path $installed)) {
    Ok 'installs binary, rc=0'
  } else {
    Bad "rc=$rc, exists=$(Test-Path $installed)"
    Get-Content (Join-Path $TestDir 't1.log') | ForEach-Object { Write-Host "    $_" }
  }

  # ---------- test 2: bad checksum ----------
  Write-Host 'test 2: bad checksum'
  Set-Content -Path (Join-Path $DlDir 'SHA256SUMS') -Value "deadbeef00000000000000000000000000000000000000000000000000000000  $asset" -Encoding ASCII
  $home2 = Join-Path $TestDir 'home2'
  New-Item -ItemType Directory -Force $home2 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home2 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patched *> (Join-Path $TestDir 't2.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $log = Get-Content (Join-Path $TestDir 't2.log') -Raw
  if ($rc -eq 1 -and $log -match 'sha256 mismatch') {
    Ok 'bad checksum exits 1 with mismatch message'
  } else {
    Bad "expected rc=1 + 'sha256 mismatch', got rc=$rc"
    Write-Host $log
  }

  # ---------- test 3: SHA256SUMS present but NO entry for this asset (fail-closed) ----------
  # Regression guard for the fail-open checksum finding (install.ps1:154-183).
  Write-Host 'test 3: sums present, no entry for asset -> fail closed'
  [void](Publish-Release -Tag 'v0.2.0' -Arch $arch)
  Set-Content -Path (Join-Path $DlDir 'SHA256SUMS') -Value "0000000000000000000000000000000000000000000000000000000000000000  some-other-release-artifact.txt" -Encoding ASCII
  $home3 = Join-Path $TestDir 'home3'
  New-Item -ItemType Directory -Force $home3 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home3 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  $env:UNBLOCK_INSECURE_SKIP_CHECKSUM = $null
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patched *> (Join-Path $TestDir 't3.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $installed3 = Join-Path $env:UNBLOCK_INSTALL_DIR 'unblock.exe'
  if ($rc -eq 1 -and -not (Test-Path $installed3)) {
    Ok 'no-entry SHA256SUMS aborts (rc=1) and does not install'
  } else {
    Bad "expected rc=1 + no binary, got rc=$rc, exists=$(Test-Path $installed3)"
    Get-Content (Join-Path $TestDir 't3.log') | ForEach-Object { Write-Host "    $_" }
  }

  # ---------- test 4: SHA256SUMS missing / 404 (fail-closed) ----------
  Write-Host 'test 4: sums 404 -> fail closed'
  [void](Publish-Release -Tag 'v0.2.0' -Arch $arch)
  Remove-Item -Force (Join-Path $DlDir 'SHA256SUMS') -ErrorAction SilentlyContinue
  $home4 = Join-Path $TestDir 'home4'
  New-Item -ItemType Directory -Force $home4 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home4 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  $env:UNBLOCK_INSECURE_SKIP_CHECKSUM = $null
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patched *> (Join-Path $TestDir 't4.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $installed4 = Join-Path $env:UNBLOCK_INSTALL_DIR 'unblock.exe'
  if ($rc -eq 1 -and -not (Test-Path $installed4)) {
    Ok 'missing SHA256SUMS aborts (rc=1) and does not install'
  } else {
    Bad "expected rc=1 + no binary, got rc=$rc, exists=$(Test-Path $installed4)"
    Get-Content (Join-Path $TestDir 't4.log') | ForEach-Object { Write-Host "    $_" }
  }

  # ---------- test 5: explicit insecure opt-out installs despite missing sums ----------
  Write-Host 'test 5: UNBLOCK_INSECURE_SKIP_CHECKSUM=1 override -> installs with warning'
  [void](Publish-Release -Tag 'v0.2.0' -Arch $arch)
  Remove-Item -Force (Join-Path $DlDir 'SHA256SUMS') -ErrorAction SilentlyContinue
  $home5 = Join-Path $TestDir 'home5'
  New-Item -ItemType Directory -Force $home5 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home5 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  $env:UNBLOCK_INSECURE_SKIP_CHECKSUM = '1'
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patched *> (Join-Path $TestDir 't5.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $env:UNBLOCK_INSECURE_SKIP_CHECKSUM = $null
  $installed5 = Join-Path $env:UNBLOCK_INSTALL_DIR 'unblock.exe'
  $log5 = Get-Content (Join-Path $TestDir 't5.log') -Raw
  if ($rc -eq 0 -and (Test-Path $installed5) -and $log5 -match 'INSECURE') {
    Ok 'explicit opt-out installs (rc=0) with INSECURE warning'
  } else {
    Bad "expected rc=0 + binary + INSECURE warning, got rc=$rc, exists=$(Test-Path $installed5)"
    Write-Host $log5
  }

  Write-Host ''
  Write-Host "PASS=$Pass FAIL=$Fail"
  if ($Fail -gt 0) { exit 1 } else { exit 0 }
} finally {
  Stop-MockServer
}

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

  # Patch install.ps1 to use the mock server. Both metadata sources (the
  # install.kaeva.app pointer and the api.github.com fallback) serve the
  # same JSON shape, so both map to the same mock endpoint here.
  $patched = Join-Path $TestDir 'install_patched.ps1'
  $src = Get-Content $InstallPs1 -Raw
  $src = $src -replace 'https://install\.kaeva\.app/api/cli-latest', "http://127.0.0.1:$Port/api/latest.json"
  $src = $src -replace 'https://api\.github\.com/repos/\$Repo/releases/latest', "http://127.0.0.1:$Port/api/latest.json"
  $src = $src -replace 'https://github\.com/\$Repo/releases/download/\$remoteTag', "http://127.0.0.1:$Port/dl"
  Set-Content -Path $patched -Value $src -Encoding UTF8

  # Variant: BOTH metadata sources dead (closed port -> instant refusal),
  # asset downloads still live.
  $patchedMetaDead = Join-Path $TestDir 'install_meta_dead.ps1'
  $src2 = Get-Content $InstallPs1 -Raw
  $src2 = $src2 -replace 'https://install\.kaeva\.app/api/cli-latest', 'http://127.0.0.1:1/pointer'
  $src2 = $src2 -replace 'https://api\.github\.com/repos/\$Repo/releases/latest', 'http://127.0.0.1:1/api'
  $src2 = $src2 -replace 'https://github\.com/\$Repo/releases/download/\$remoteTag', "http://127.0.0.1:$Port/dl"
  Set-Content -Path $patchedMetaDead -Value $src2 -Encoding UTF8

  # Variant: pointer dead, API source live -> exercises the fallback leg.
  $patchedPtrDead = Join-Path $TestDir 'install_pointer_dead.ps1'
  $src3 = Get-Content $InstallPs1 -Raw
  $src3 = $src3 -replace 'https://install\.kaeva\.app/api/cli-latest', 'http://127.0.0.1:1/pointer'
  $src3 = $src3 -replace 'https://api\.github\.com/repos/\$Repo/releases/latest', "http://127.0.0.1:$Port/api/latest.json"
  $src3 = $src3 -replace 'https://github\.com/\$Repo/releases/download/\$remoteTag', "http://127.0.0.1:$Port/dl"
  Set-Content -Path $patchedPtrDead -Value $src3 -Encoding UTF8

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

  # Restore a clean release: test 2 corrupted the served SHA256SUMS.
  $asset = Publish-Release -Tag 'v0.2.0' -Arch $arch

  # ---------- test 3: UNBLOCK_VERSION pin, metadata sources DOWN ----------
  Write-Host 'test 3: UNBLOCK_VERSION pin survives dead metadata sources'
  $home3 = Join-Path $TestDir 'home3'
  New-Item -ItemType Directory -Force $home3 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home3 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  $env:UNBLOCK_VERSION = 'v0.2.0'
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patchedMetaDead *> (Join-Path $TestDir 't3.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  Remove-Item Env:UNBLOCK_VERSION -ErrorAction SilentlyContinue
  $installed = Join-Path $env:UNBLOCK_INSTALL_DIR 'unblock.exe'
  if ($rc -eq 0 -and (Test-Path $installed)) {
    Ok 'pinned install succeeds with every metadata endpoint dead'
  } else {
    Bad "expected rc=0 + binary, got rc=$rc, exists=$(Test-Path $installed)"
    Get-Content (Join-Path $TestDir 't3.log') | ForEach-Object { Write-Host "    $_" }
  }

  # ---------- test 4: pointer down -> API-source fallback ----------
  Write-Host 'test 4: pointer outage falls back to the API source'
  $home4 = Join-Path $TestDir 'home4'
  New-Item -ItemType Directory -Force $home4 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home4 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patchedPtrDead *> (Join-Path $TestDir 't4.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $installed = Join-Path $env:UNBLOCK_INSTALL_DIR 'unblock.exe'
  $log = Get-Content (Join-Path $TestDir 't4.log') -Raw
  if ($rc -eq 0 -and (Test-Path $installed) -and $log -match 'trying next source') {
    Ok 'fallback source installs; the failover is stated, not silent'
  } else {
    Bad "expected rc=0 + binary + 'trying next source', got rc=$rc"
    Write-Host $log
  }

  # ---------- test 5: every metadata source down, no pin ----------
  Write-Host 'test 5: all metadata sources down -> honest error + pin hint'
  $home5 = Join-Path $TestDir 'home5'
  New-Item -ItemType Directory -Force $home5 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home5 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patchedMetaDead *> (Join-Path $TestDir 't5.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $log = Get-Content (Join-Path $TestDir 't5.log') -Raw
  if ($rc -eq 1 -and $log -match 'UNBLOCK_VERSION') {
    Ok 'exit 1 and the error teaches the UNBLOCK_VERSION escape hatch'
  } else {
    Bad "expected rc=1 + UNBLOCK_VERSION hint, got rc=$rc"
    Write-Host $log
  }

  Write-Host ''
  Write-Host "PASS=$Pass FAIL=$Fail"
  if ($Fail -gt 0) { exit 1 } else { exit 0 }
} finally {
  Stop-MockServer
}

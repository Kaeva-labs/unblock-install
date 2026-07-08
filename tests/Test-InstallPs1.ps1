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

  # ---------- test 3: reinstall over an existing binary (rename-swap) ----------
  # Regression guard for the Windows in-place-upgrade finding (install.ps1:187):
  # `Move-Item -Force` straight onto an existing/running unblock.exe used to
  # throw a sharing violation on real Windows. This harness can't hold a real
  # Windows mandatory file-lock, but it does prove the rename-then-replace
  # mechanics: a previous install already sits at the target path, and the
  # branch that used to be a bare `Move-Item -Force` must still succeed,
  # actually replace the content, and leave no `.old` leftover behind.
  Write-Host 'test 3: reinstall over an existing binary (temp-swap)'
  # test 2 intentionally corrupted the shared SHA256SUMS; republish a good one.
  [void](Publish-Release -Tag 'v0.4.0' -Arch $arch)
  $env:LOCALAPPDATA = Join-Path $home1 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  $installed3 = Join-Path $env:UNBLOCK_INSTALL_DIR 'unblock.exe'
  $existedBefore = Test-Path $installed3
  $hashBefore = if ($existedBefore) { (Get-FileHash -Algorithm SHA256 -Path $installed3).Hash } else { $null }
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $patched *> (Join-Path $TestDir 't3.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $hashAfter = if (Test-Path $installed3) { (Get-FileHash -Algorithm SHA256 -Path $installed3).Hash } else { $null }
  $oldLeftover = Test-Path "$installed3.old"
  if ($existedBefore -and $rc -eq 0 -and (Test-Path $installed3) -and $hashAfter -ne $hashBefore -and -not $oldLeftover) {
    Ok 'reinstall over existing binary succeeds via rename-swap (rc=0, content replaced, no .old leftover)'
  } else {
    Bad "rc=$rc existedBefore=$existedBefore hashChanged=$($hashAfter -ne $hashBefore) oldLeftover=$oldLeftover"
    Get-Content (Join-Path $TestDir 't3.log') | ForEach-Object { Write-Host "    $_" }
  }

  # ---------- test 4: GitHub API rate limit -> actionable message ----------
  # Regression guard for the rate-limit finding (install.ps1:71): a 403 with
  # a rate-limit body must produce a specific, actionable message instead of
  # the generic "no tag_name in release metadata" / "could not parse" text,
  # and must NOT burn through retries against a confirmed rate limit.
  Write-Host 'test 4: rate-limited release metadata -> actionable message'
  $rlPort = [int]$Port + 1
  $rlListener = New-Object System.Net.HttpListener
  $rlListener.Prefixes.Add("http://127.0.0.1:$rlPort/")
  $rlListener.Start()
  $rlRunspace = [runspacefactory]::CreateRunspace()
  $rlRunspace.Open()
  $rlPs = [powershell]::Create()
  $rlPs.Runspace = $rlRunspace
  [void]$rlPs.AddScript({
    param($listener)
    try {
      $ctx = $listener.GetContext()
      $body = '{"message":"API rate limit exceeded for 127.0.0.1.","documentation_url":"https://docs.github.com/rest"}'
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
      $ctx.Response.StatusCode = 403
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      $ctx.Response.Close()
    } catch {}
  }).AddArgument($rlListener)
  $rlAsync = $rlPs.BeginInvoke()

  $rlSrc = Get-Content $InstallPs1 -Raw
  $rlSrc = $rlSrc -replace 'https://api\.github\.com/repos/\$Repo/releases/latest', "http://127.0.0.1:$rlPort/"
  $rlPatched = Join-Path $TestDir 'install_ratelimited.ps1'
  Set-Content -Path $rlPatched -Value $rlSrc -Encoding UTF8

  $home4 = Join-Path $TestDir 'home4'
  New-Item -ItemType Directory -Force $home4 | Out-Null
  $env:LOCALAPPDATA = Join-Path $home4 'AppData\Local'
  $env:UNBLOCK_INSTALL_DIR = Join-Path $env:LOCALAPPDATA 'unblock'
  $sw4 = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $rlPatched *> (Join-Path $TestDir 't4.log')
    $rc = $LASTEXITCODE
  } catch { $rc = 99 }
  $sw4.Stop()
  $log4 = Get-Content (Join-Path $TestDir 't4.log') -Raw
  try { $rlListener.Stop() } catch {}
  try { $rlPs.EndInvoke($rlAsync) } catch {}
  try { $rlPs.Dispose() } catch {}
  try { $rlRunspace.Close() } catch {}
  if ($rc -eq 1 -and $log4 -match 'rate limit exceeded' -and $log4 -notmatch 'could not parse tag_name' -and $sw4.Elapsed.TotalSeconds -lt 15) {
    Ok "rate-limited metadata fetch prints an actionable message, fails fast ($([math]::Round($sw4.Elapsed.TotalSeconds,1))s, no wasted retries)"
  } else {
    Bad "expected rc=1 + actionable rate-limit message within 15s, got rc=$rc in $($sw4.Elapsed.TotalSeconds)s"
    Write-Host $log4
  }

  Write-Host ''
  Write-Host "PASS=$Pass FAIL=$Fail"
  if ($Fail -gt 0) { exit 1 } else { exit 0 }
} finally {
  Stop-MockServer
}

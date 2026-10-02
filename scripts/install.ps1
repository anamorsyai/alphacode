#!/usr/bin/env pwsh
# install.ps1 -- PowerShell installer for Alphacode (Windows + cross-platform pwsh)
#
# Usage:
#   iwr -useb https://raw.githubusercontent.com/dragonked2/alphacode/main/scripts/install.ps1 | iex
#   iwr -useb ... | iex -Version v1.0.0
#   iwr -useb ... | iex -Prefix "$env:LOCALAPPDATA\Programs\alphacode"
#   iwr -useb ... | iex -FromSource                  # skip release, build locally
#   iwr -useb ... | iex -SourceRef main               # build from a specific ref
#   iwr -useb ... | iex -AddPath                      # add the bin dir to the user PATH
#   iwr -useb ... | iex -AddPath -PathDryRun          # show what -AddPath would do, write nothing
#
# By default, tries to download a prebuilt release asset. If no release is
# published (or there is no asset for this OS/arch), it falls back to
# building from source. Requires: git, cargo, rustc >= 1.91.
#
# PATH handling (-AddPath) mirrors what install.sh --add-path does on Unix, so
# the two installers offer the same capability. It is deliberately narrow:
#   * it writes ONLY HKCU\Environment\Path. The machine-wide PATH is never
#     touched (that needs admin and would affect every user on the box);
#   * it never rewrites $env:PATH. The session PATH is the merge of user +
#     machine + anything the session added; rebuilding it from the registry
#     would silently drop those session-only entries for this shell and for
#     anything it spawns. The already-running shell is left alone on purpose --
#     it keeps working, and a new shell picks the value up;
#   * it appends rather than prepends, so no existing entry changes precedence;
#   * it is idempotent, and refuses to run twice;
#   * it preserves the registry value *kind*, so a PATH using %USERPROFILE%
#     style references stays expandable (see Add-AlphacodeToUserPath).

[CmdletBinding()]
param(
  [string]$Version   = $env:ALPHACODE_VERSION,
  [string]$Repo      = ($env:ALPHACODE_REPO -as [string]),
  [string]$Prefix    = $env:ALPHACODE_PREFIX,
  [string]$BinDir    = $env:ALPHACODE_BIN_DIR,
  [switch]$NoPath,
  [switch]$AddPath,
  [switch]$PathDryRun,
  [switch]$FromSource,
  [switch]$SourceOnly,
  [string]$SourceRef = $env:ALPHACODE_SOURCE_REF
)

$ErrorActionPreference = 'Stop'

# Is this Windows?
#
# Deliberately NOT `$IsWindows`. That variable only exists in PowerShell 6+,
# and the documented invocation for this script is `iwr ... | iex`, which on a
# default Windows machine runs Windows PowerShell 5.1 -- where `$IsWindows` is
# undefined and evaluates to $null. Testing it there is always false, so the
# Windows branch below was dead code on the very shell most users run, and the
# install directory silently became "$HOME/.local" instead of LOCALAPPDATA.
# [Environment]::OSVersion.Platform exists in every edition and needs no
# PowerShell version.
function Test-AlphacodeWindows {
    [CmdletBinding()]
    param()
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

if (-not $Repo)    { $Repo    = 'dragonked2/alphacode' }
if (-not $Version) { $Version = 'latest' }
if (-not $Prefix)  {
  if (Test-AlphacodeWindows) { $Prefix = "$env:LOCALAPPDATA\alphacode" }
  else                        { $Prefix = "$HOME/.local" }
}
if (-not $BinDir)  { $BinDir = Join-Path $Prefix 'bin' }

function Print([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn ([string]$msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
function Fail ([string]$msg) { Write-Host "[fail] $msg" -ForegroundColor Red; exit 1 }

# --- user PATH ---------------------------------------------------------------
#
# Split into a pure planner and an effectful applier on purpose. The planner
# takes the current user PATH as a *string argument* and touches nothing, so it
# can be exercised over a matrix of shapes (empty, trailing separators, case
# differences, %VAR% references, sibling directories) without a registry, and
# without any risk of the test itself mutating the machine it runs on. That is
# what scripts/tests/install-path.tests.ps1 drives.

# Normalise a PATH entry for comparison: trimmed, and without trailing
# separators. Windows treats `C:\a\bin` and `C:\a\bin\` as the same directory,
# so without this every re-run would append a duplicate.
function ConvertTo-AlphacodeComparablePathEntry([string]$Entry) {
    if ($null -eq $Entry) { return '' }
    return $Entry.Trim().TrimEnd('\', '/')
}

# Decide what the user PATH should become. Pure: no registry, no environment
# mutation, no I/O.
#
# Appends rather than prepends. Appending is the only option that provably
# cannot change which executable wins for any pre-existing entry: nothing moves,
# so nothing that used to resolve to X can start resolving to Y. Prepending
# would be defensible for the same directory twice, but it reorders PATH, and
# PATH order decides which `git`/`python`/`node` a script gets.
function Get-AlphacodePathPlan {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$UserPath,
        [Parameter(Mandatory)][string]$BinDir
    )

    $target = ConvertTo-AlphacodeComparablePathEntry $BinDir
    if ([string]::IsNullOrWhiteSpace($target)) {
        throw 'BinDir must not be empty.'
    }

    # Split, drop empty segments (a doubled ';;' from a hand-edited PATH), but
    # keep each entry's original text so nothing is rewritten on the way out.
    $entries = @()
    if ($null -ne $UserPath) {
        $entries = @($UserPath -split ';' | Where-Object { $_ -ne '' })
    }

    foreach ($entry in $entries) {
        if ((ConvertTo-AlphacodeComparablePathEntry $entry) -ieq $target) {
            # Already there. Return the value untouched rather than a rebuilt
            # one, so a re-run cannot normalise or reorder the user's PATH.
            return [pscustomobject]@{
                AlreadyPresent = $true
                Original      = $UserPath
                Value         = $UserPath
            }
        }
    }

    $value = if ($entries.Count -eq 0) { $target } else { ($entries -join ';') + ';' + $target }
    return [pscustomobject]@{
        AlreadyPresent = $false
        Original      = $UserPath
        Value         = $value
    }
}

# Tell already-running GUI processes (Explorer, the taskbar, anything that
# caches the environment) that `Environment` changed, so a *new* terminal picks
# the value up without a sign-out. This is the same broadcast `setx` and
# Chocolatey send; without it the write silently succeeds and appears to do
# nothing until the next reboot, which is the usual "the installer lied to me"
# report.
#
# Failure here is not fatal: the registry value is already committed, and the
# user can still open a new shell. Best-effort by design.
function Publish-AlphacodeEnvironmentChange {
    [CmdletBinding()]
    param()

    try {
        if (-not ('AlphacodeInstaller.Native' -as [type])) {
            Add-Type -Namespace 'AlphacodeInstaller' -Name 'Native' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        # SMTO_ABORTIFHUNG = 0x0002. A hung Explorer would otherwise make the
        # installer block for the whole timeout.
        $result = [UIntPtr]::Zero
        [void][AlphacodeInstaller.Native]::SendMessageTimeout(
            [IntPtr]0xffff,   # HWND_BROADCAST
            0x001A,           # WM_SETTINGCHANGE
            [UIntPtr]::Zero,
            'Environment',
            0x0002,           # SMTO_ABORTIFHUNG
            5000,
            [ref]$result)
    } catch {
        Write-Host "[warn] Could not broadcast the environment change: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "[warn] Open a new terminal for the PATH change to take effect." -ForegroundColor Yellow
    }
}

# Read HKCU\Environment\Path *raw*.
#
# Two things matter here and both are reasons not to use
# [Environment]::GetEnvironmentVariable('Path','User'):
#   1. That call expands REG_EXPAND_SZ, so a PATH containing `%USERPROFILE%\bin`
#      comes back already substituted. Writing it straight back would freeze
#      today's profile path into the registry forever -- a silent, permanent
#      regression for anyone whose user directory is renamed or whose install
#      is copied to another machine.
#   2. It merges nothing, but it also hides the value *kind*, which is needed to
#      write it back correctly (below).
function Get-AlphacodeRawUserPath {
    [CmdletBinding()]
    param()

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if ($null -eq $key) { return [pscustomobject]@{ Exists = $false; Value = $null; Kind = [Microsoft.Win32.RegistryValueKind]::String } }
    try {
        $exists = $key.GetValueNames() -contains 'Path'
        $kind = if ($exists) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::String }
        $raw = if ($exists) {
            $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } else { $null }
        return [pscustomobject]@{ Exists = $exists; Value = $raw; Kind = $kind }
    } finally {
        $key.Close()
    }
}

# Append the bin dir to the *user* PATH, idempotently. Returns a result object
# describing what happened so the caller can report accurately.
function Add-AlphacodeToUserPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BinDir,
        [switch]$DryRun
    )

    if (-not (Test-AlphacodeWindows)) {
        Write-Host "[warn] -AddPath only applies on Windows; on other platforms use your shell profile." -ForegroundColor Yellow
        return [pscustomobject]@{ Status = 'skipped'; Reason = 'not-windows' }
    }

    $current = Get-AlphacodeRawUserPath
    $plan = Get-AlphacodePathPlan -UserPath $current.Value -BinDir $BinDir

    if ($plan.AlreadyPresent) {
        Print "Already on your user PATH: $BinDir"
        return [pscustomobject]@{ Status = 'already-present'; Value = $plan.Value }
    }

    # REG_EXPAND_SZ values are limited to 32767 characters. Silently truncating
    # here would produce a PATH that is missing whichever entries fell off the
    # end, so refuse instead and let the user decide.
    if ($plan.Value.Length -gt 32767) {
        Fail "Adding '$BinDir' would make your user PATH $($plan.Value.Length) characters, over the Windows limit of 32767. Not writing it -- trim your user PATH and re-run."
    }

    if ($DryRun) {
        Write-Host "[dry-run] HKCU\Environment\Path would be set to:"
        Write-Host "[dry-run]   $($plan.Value)"
        Write-Host "[dry-run] (nothing was written; re-run without -PathDryRun to apply)"
        return [pscustomobject]@{ Status = 'dry-run'; Value = $plan.Value }
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) {
        Warn 'Could not open HKCU\Environment for writing; PATH not modified.'
        return [pscustomobject]@{ Status = 'failed'; Reason = 'key-unavailable' }
    }
    try {
        # Write back with the value kind we read. Defaulting to String here would
        # convert an ExpandString PATH to a literal one and break every %VAR%
        # reference in it.
        $kind = if ($current.Kind -eq [Microsoft.Win32.RegistryValueKind]::Unknown) {
            [Microsoft.Win32.RegistryValueKind]::ExpandString
        } else { $current.Kind }
        $key.SetValue('Path', $plan.Value, $kind)
    } finally {
        $key.Close()
    }

    Publish-AlphacodeEnvironmentChange
    Print "Added to your user PATH: $BinDir"
    Write-Host "    Open a new terminal to pick it up (this one is unchanged on purpose)."
    return [pscustomobject]@{ Status = 'added'; Value = $plan.Value }
}

# --- build_from_source -------------------------------------------------------
#
# Fallback: no release artifact for this platform/arch. Clone the repo, build
# with cargo, and copy the resulting binary into $BinDir.
#
# Requires: git, cargo, rustc >= 1.91, and a working C toolchain. This can
# take 5-30 minutes on a first build.
function Build-FromSource {
  if (-not (Get-Command git   -ErrorAction SilentlyContinue)) { Fail "git is required to build from source" }
  if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { Fail "cargo is required to build from source (install Rust from https://rustup.rs)" }

  # rustc >= 1.91 (edition 2024 + current dependency MSRV) check.
  $rv = (& rustc --version) 2>$null
  if ($rv -match 'rustc\s+(\d+)\.(\d+)') {
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
    if ($major -lt 1 -or ($major -eq 1 -and $minor -lt 91)) {
      Fail "rustc $($Matches[0]) is too old; need >= 1.91 (update via 'rustup update')"
    }
  }

  $srcDir = Join-Path ([System.IO.Path]::GetTempPath()) ("alphacode-src-" + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $srcDir | Out-Null

  try {
    Print "Cloning $Repo into a temporary build directory ..."
    $cloneUrl = "https://github.com/$Repo.git"
    if ($SourceRef) {
      & git clone --depth 1 --branch $SourceRef $cloneUrl "$srcDir\src" | Out-Null
      if ($LASTEXITCODE -ne 0) { Fail "git clone failed (ref: $SourceRef)" }
    } else {
      & git clone --depth 1 $cloneUrl "$srcDir\src" | Out-Null
      if ($LASTEXITCODE -ne 0) { Fail "git clone failed" }
    }

    Print "Compiling alphacode (this can take 5-30 minutes on a first build) ..."
    # NOTE: no --locked on purpose. The committed Cargo.lock does not list
    # platform-conditional deps for every target triple, and CI itself runs
    # without `--locked` (see .github/workflows/release.yml: `locked: false`).
    # If we passed --locked here, a fresh source build on a platform the
    # lockfile wasn't regenerated for would fail with
    # "Cargo.lock needs to be updated".
    & cargo build --release --manifest-path "$srcDir\src\Cargo.toml"
    if ($LASTEXITCODE -ne 0) { Fail "cargo build failed" }

    $builtExe = Join-Path "$srcDir\src\target\release" 'alphacode.exe'
    if (-not (Test-Path $builtExe)) {
      Fail "build succeeded but target\release\alphacode.exe was not produced"
    }

    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $destExe = Join-Path $BinDir 'alphacode.exe'
    Copy-Item -Path $builtExe -Destination $destExe -Force
    Print "Installed -> $destExe (built from source)"
  } finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $srcDir
  }
}

# --- Architecture ------------------------------------------------------------

switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { $Arch = 'x86_64' }
  'ARM64' { $Arch = 'arm64' }
  default { Fail "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}

if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
  $Platform = 'windows'
  $asset   = "alphacode-windows-$Arch.zip"
} else {
  Fail "this script is for Windows. On Linux/macOS use scripts/install.sh."
}

# --- Version -----------------------------------------------------------------

# Short-circuit: build from source only.
if ($FromSource) {
  Print '[FromSource] requested, skipping release download.'
  Build-FromSource
  return
}

if ($Version -eq 'latest') {
  Print "Resolving latest release from $Repo ..."
  $rel = $null
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
  } catch {
    $rel = $null
  }
  if (-not $rel -or -not $rel.tag_name) {
    if ($SourceOnly) { Fail "no release found for $Repo and -SourceOnly is set" }
    Warn "no GitHub release found for $Repo -- falling back to building from source."
    Build-FromSource
    Print "Done."
    return
  }
  $Version = $rel.tag_name
  Print "Latest release: $Version"
}
$VersionNoV = $Version.TrimStart('v')

# --- Download ----------------------------------------------------------------

$Tmp      = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString('N')
$ZipPath  = Join-Path $Tmp $asset
$Extract  = Join-Path $Tmp 'extract'
$Url      = "https://github.com/$Repo/releases/download/$Version/$asset"
New-Item -ItemType Directory -Force -Path $Tmp,$Extract | Out-Null

Print "Downloading $Url"
try {
  Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing
} catch {
  if ($SourceOnly) { Fail "download failed: $($_.Exception.Message)" }
  Warn "no prebuilt asset for $Platform/$Arch at $Version -- falling back to building from source."
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Tmp
  Build-FromSource
  Print "Done."
  return
}

# Optional checksum verification
try {
  $sums = Invoke-WebRequest -Uri "https://github.com/$Repo/releases/download/$Version/SHA256SUMS" -UseBasicParsing -ErrorAction Stop
  $expected = ($sums.Content -split "`n" | Where-Object { $_ -like "*$asset*" } | Select-Object -First 1)
  if ($expected) {
    $expectedHash = ($expected -split ' ')[0]
    $actualHash   = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()
    if ($expectedHash -ne $actualHash) {
      Fail "checksum mismatch (expected $expectedHash, got $actualHash)"
    }
    Print "Checksum verified."
  }
} catch {
  Warn "could not fetch/verify SHA256SUMS -- continuing"
}

# --- Extract -----------------------------------------------------------------

Print "Extracting ..."
try {
  Expand-Archive -Path $ZipPath -DestinationPath $Extract -Force
} catch {
  Fail "extract failed: $($_.Exception.Message)"
}

$binary = Get-ChildItem -Path $Extract -Recurse -Filter 'alphacode.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $binary) {
  Fail "extracted archive did not contain 'alphacode.exe'"
}

# --- Install -----------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$installedExe = Join-Path $BinDir 'alphacode.exe'
Copy-Item -Path $binary.FullName -Destination $installedExe -Force

# Also copy .bin payload files if present (release wrapper scripts need them).
$payloadFiles = Get-ChildItem -Path $Extract -Recurse -Filter '*.bin' -ErrorAction SilentlyContinue
foreach ($pf in $payloadFiles) {
    $destBin = Join-Path $BinDir $pf.Name
    Copy-Item -Path $pf.FullName -Destination $destBin -Force
}

Print "Installed -> $installedExe"

# Verify the installed binary works. Use --version (handled by clap before
# any application logic) so the check succeeds even if a re-exec path would
# otherwise interfere with subcommand parsing.
# Brief pause: Windows SmartScreen / Defender may need a moment to allow a
# freshly-copied executable to run.
Start-Sleep -Milliseconds 500
try {
  $proc = Start-Process -FilePath "$BinDir\alphacode.exe" -ArgumentList '--version' `
    -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$Tmp\version_stdout.txt" `
    -RedirectStandardError "$Tmp\version_stderr.txt"
  $exitCode = $proc.ExitCode
  $stdout = if (Test-Path "$Tmp\version_stdout.txt") { Get-Content "$Tmp\version_stdout.txt" -Raw } else { '' }
  $stderr = if (Test-Path "$Tmp\version_stderr.txt") { Get-Content "$Tmp\version_stderr.txt" -Raw } else { '' }
  if ($exitCode -eq 0 -and $stdout) {
    $versionLine = ($stdout -split "`n" | Where-Object { $_ -match 'alphacode\s+v[\d.]+' } | Select-Object -First 1)
    if ($versionLine) {
      $version = ($versionLine -replace '.*alphacode\s+(v[\d.]+).*','$1')
      Print "Installed version: $version"
    } else {
      Print "Installed (could not parse version from: $stdout)"
    }
  } else {
    $detail = if ($stderr) { $stderr.Trim() } else { "exit code $exitCode" }
    Warn "Binary installed but could not verify version: $detail"
  }
} catch {
  $excMsg = "$($_.Exception.Message)"
  if ([string]::IsNullOrWhiteSpace($excMsg)) {
    Write-Host '[warn] Binary installed but could not verify version: Start-Process failed (no exception detail; check file permissions and antivirus)' -ForegroundColor Yellow
  } else {
    Warn "Binary installed but could not verify version: $excMsg"
  }
}

if ($AddPath) {
  $result = Add-AlphacodeToUserPath -BinDir $BinDir -DryRun:$PathDryRun
  if ($result.Status -eq 'failed') {
    Write-Host ""
    Write-Host "Next step: add the install location to your user PATH by hand." -ForegroundColor Yellow
    Write-Host "  See https://github.com/dragonked2/alphacode#install for PATH instructions."
  }
} elseif (-not $NoPath) {
  # Existing-session check only. $env:PATH is the merged user+machine+session
  # value, so a hit here means "resolvable right now"; its absence does NOT mean
  # the user PATH is missing the entry (a session-only PATH can make it look
  # absent). That is why this stays a hint rather than a claim, and why -AddPath
  # reads the registry directly instead of trusting this check.
  $haveIt = ($env:PATH -split [IO.Path]::PathSeparator) | Where-Object { $_ -ieq $BinDir } | Select-Object -First 1
  if (-not $haveIt) {
    Write-Host ""
    Write-Host "Next step: add the install location to your user PATH." -ForegroundColor Yellow
    Write-Host "  Re-run with -AddPath to do it automatically, or see"
    Write-Host "  https://github.com/dragonked2/alphacode#install for manual instructions."
    Write-Host ""
    Write-Host "Then open a new shell and:"
    Write-Host "  alphacode login"
    Write-Host "  alphacode"
  }
}

Remove-Item -Recurse -Force $Tmp
Print "Done."
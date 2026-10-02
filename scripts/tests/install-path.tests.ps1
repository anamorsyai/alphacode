#!/usr/bin/env pwsh
# install-path.tests.ps1 -- behaviour tests for the installer's PATH logic.
#
# Run directly:
#   pwsh -File scripts/tests/install-path.tests.ps1
#
# These tests exist because the PATH code mutates a system-level setting, and
# "it looked right" is not evidence for that class of change. Every assertion
# below runs against the *pure* planner, which takes the current user PATH as a
# string and touches no registry and no environment variable, so the suite is
# safe to run anywhere -- including CI, where a mistake would otherwise rewrite
# the runner's own PATH.
#
# Deliberately NOT tested here: Add-AlphacodeToUserPath / Remove-AlphacodeFromUserPath.
# Those touch HKCU and cannot be exercised without mutating the machine. What is
# verified is that the decision they make -- the only part with real logic -- is
# correct, and that the entry point refuses to run on a dry run.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Installer = Join-Path $RepoRoot 'scripts/install.ps1'

if (-not (Test-Path $Installer)) {
    throw "installer not found at $Installer"
}

# ---------------------------------------------------------------------------
# Load only the function definitions from install.ps1.
#
# install.ps1 must stay a single self-contained file (it is fetched with
# `iwr ... | iex`, which cannot resolve a sibling file), so the tests cannot
# dot-source a helper module. Parsing the AST and evaluating just the function
# definitions gives the same coverage without executing the installer body --
# no download, no install, no registry writes.
#
# The definitions are returned as one scriptblock rather than being defined
# inside a helper function: a function defined in a helper's local scope
# disappears when the helper returns, which would leave every test below
# calling a command that does not exist.
# ---------------------------------------------------------------------------
function Get-InstallerFunctionDefinitions {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "failed to parse $Path : $($errors[0].Message)"
    }

    $functions = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    )
    if ($functions.Count -eq 0) {
        throw "no functions found in $Path -- the AST extraction is broken, so these tests would vacuously pass"
    }

    $text = ($functions | ForEach-Object { $_.Extent.Text }) -join "`n"
    return [pscustomobject]@{
        Names      = @($functions | ForEach-Object { $_.Name })
        Definition = [scriptblock]::Create($text)
    }
}

$installerFunctions = Get-InstallerFunctionDefinitions -Path $Installer
. $installerFunctions.Definition

# Verify the functions are actually callable, not merely present in the AST.
# A name-only check passed while every test failed with "not recognized",
# because the definitions had gone out of scope -- so this asserts on
# Get-Command, which reflects reality.
$missing = @($installerFunctions.Names | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
if ($missing.Count -gt 0) {
    throw "these functions were extracted but are not callable: $($missing -join ', ')"
}
foreach ($required in @('Get-AlphacodePathPlan', 'ConvertTo-AlphacodeComparablePathEntry', 'Add-AlphacodeToUserPath', 'Test-AlphacodeWindows')) {
    if ($installerFunctions.Names -notcontains $required) {
        throw "expected function '$required' was not found in install.ps1 (found: $($installerFunctions.Names -join ', '))"
    }
}

# ---------------------------------------------------------------------------
# Minimal test harness (no Pester dependency, so CI needs nothing installed).
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "  ok   $Name"
    } catch {
        $script:Failed++
        Write-Host "  FAIL $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) {
        throw "expected [$Expected] but got [$Actual]$(if ($Because) { " ($Because)" })"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because = '')
    if (-not $Condition) {
        throw "expected condition to hold$(" ($Because)")"
    }
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Because = '')
    if ($Haystack -notlike "*$Needle*") {
        throw "expected to find [$Needle] in [$Haystack]$(" ($Because)")"
    }
}

Write-Host "install.ps1 PATH logic" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Adding.
# ---------------------------------------------------------------------------

It 'appends the bin dir to a non-empty user PATH' {
    $plan = Get-AlphacodePathPlan -UserPath 'C:\a;C:\b' -BinDir 'C:\tools\alphacode\bin'
    Assert-True -Condition (-not $plan.AlreadyPresent) -Because 'the dir was absent'
    Assert-Equal 'C:\a;C:\b;C:\tools\alphacode\bin' $plan.Value
}

It 'uses the bin dir alone when there is no user PATH' {
    foreach ($empty in @($null, '')) {
        $plan = Get-AlphacodePathPlan -UserPath $empty -BinDir 'C:\tools\bin'
        Assert-Equal 'C:\tools\bin' $plan.Value "user PATH was [$empty]"
    }
}

It 'is idempotent' {
    $first = Get-AlphacodePathPlan -UserPath 'C:\a' -BinDir 'C:\b'
    $second = Get-AlphacodePathPlan -UserPath $first.Value -BinDir 'C:\b'
    Assert-True $second.AlreadyPresent -Because 'the second run must see it present'
    Assert-Equal $first.Value $second.Value -Because 'a re-run must not change the value'
}

It 'treats a trailing separator as the same directory' {
    $plan = Get-AlphacodePathPlan -UserPath 'C:\tools\alphacode\bin\' -BinDir 'C:\tools\alphacode\bin'
    Assert-True $plan.AlreadyPresent -Because 'Windows treats these as one directory'
}

It 'matches case-insensitively' {
    $plan = Get-AlphacodePathPlan -UserPath 'c:\TOOLS\Alphacode\BIN' -BinDir 'C:\tools\alphacode\bin'
    Assert-True $plan.AlreadyPresent -Because 'PATH comparison must be case-insensitive'
}

It 'collapses doubled separators without losing entries' {
    # A hand-edited PATH routinely contains ';;'. Every real entry must survive
    # the rewrite; only the empty segment is dropped.
    $plan = Get-AlphacodePathPlan -UserPath 'C:\a;;C:\b;' -BinDir 'C:\c'
    Assert-Equal 'C:\a;C:\b;C:\c' $plan.Value
}

It 'preserves %VAR% references verbatim' {
    # The whole reason the applier reads the registry raw. If a %VAR% were
    # expanded here it would be frozen to today's literal path.
    $plan = Get-AlphacodePathPlan -UserPath '%USERPROFILE%\bin;C:\a' -BinDir 'C:\c'
    Assert-Equal '%USERPROFILE%\bin;C:\a;C:\c' $plan.Value
}

It 'preserves entries containing spaces' {
    $plan = Get-AlphacodePathPlan -UserPath 'C:\Program Files\Git\cmd' -BinDir 'C:\c'
    Assert-Equal 'C:\Program Files\Git\cmd;C:\c' $plan.Value
}

It 'does not treat a sibling directory as the target' {
    # Prefix confusion: removing/appending must match the whole entry, not a
    # string prefix of it.
    foreach ($sibling in @('C:\tools\alphacode\bin-old', 'C:\tools\alphacode\bin2', 'C:\tools\alphacode')) {
        $plan = Get-AlphacodePathPlan -UserPath $sibling -BinDir 'C:\tools\alphacode\bin'
        Assert-True (-not $plan.AlreadyPresent) -Because "[$sibling] is a different directory"
    }
}

It 'appends rather than prepends, so no existing entry changes precedence' {
    $plan = Get-AlphacodePathPlan -UserPath 'C:\first;C:\second' -BinDir 'C:\zzz'
    Assert-Equal 'C:\first;C:\second;C:\zzz' $plan.Value -Because 'order must be unchanged'
    Assert-True ($plan.Value.StartsWith('C:\first;')) -Because 'the first entry must still be first'
}

It 'rejects an empty bin dir instead of writing a stray separator' {
    $threw = $false
    try { Get-AlphacodePathPlan -UserPath 'C:\a' -BinDir '   ' | Out-Null } catch { $threw = $true }
    Assert-True $threw -Because 'an empty BinDir must be refused'
}

It 'never derives the new value from the session PATH' {
    # The bug this guards against: reading $env:PATH (user+machine+session
    # merged) and writing that back would silently drop session-only entries for
    # every future shell. The planner only ever sees what it is handed.
    $sessionBefore = $env:PATH
    $plan = Get-AlphacodePathPlan -UserPath 'C:\only-user-entry' -BinDir 'C:\c'
    Assert-Equal $sessionBefore $env:PATH -Because 'planning must not touch the session PATH'
    Assert-True ($plan.Value -notlike "*$([IO.Path]::PathSeparator)*$([IO.Path]::PathSeparator)*") `
        -Because 'the result must be a single PATH, not a doubled-up merge'
}

# ---------------------------------------------------------------------------
# The applier's guard rails.
#
# Only the dry-run path is exercised: it must produce a plan and commit nothing.
# ---------------------------------------------------------------------------

It 'detects Windows without relying on $IsWindows' {
    # $IsWindows only exists in PowerShell 6+. This script is invoked with
    # `iwr ... | iex`, which runs Windows PowerShell 5.1 by default, where the
    # variable is undefined and evaluates to $null -- so a test against it is
    # always false there and the Windows branch is dead code on the shell most
    # users actually run.
    Assert-True -Condition (Test-AlphacodeWindows) -Because 'this suite is running on Windows'
    Assert-True -Condition ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) `
        -Because 'the helper must agree with the runtime, not with a PS6-only variable'
}

It 'dry run reports a plan and writes nothing' {
    if (-not (Test-AlphacodeWindows)) { return }   # the applier is a no-op off Windows
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    try {
        $before = if ($null -ne $key -and ($key.GetValueNames() -contains 'Path')) {
            $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } else { $null }
    } finally { if ($null -ne $key) { $key.Close() } }

    $beforeProcess = $env:PATH
    # A directory that cannot plausibly already be on the PATH.
    $probe = 'C:\alphacode-path-test-' + [guid]::NewGuid().ToString('N')
    $result = Add-AlphacodeToUserPath -BinDir $probe -DryRun

    Assert-Equal 'dry-run' $result.Status
    Assert-Contains $result.Value $probe

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    try {
        $after = if ($null -ne $key -and ($key.GetValueNames() -contains 'Path')) {
            $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } else { $null }
    } finally { if ($null -ne $key) { $key.Close() } }

    Assert-Equal $before $after -Because 'a dry run must not write the registry'
    Assert-Equal $beforeProcess $env:PATH -Because 'a dry run must not rewrite the session PATH'
}

# ---------------------------------------------------------------------------
Write-Host ""
if ($script:Failed -eq 0) {
    Write-Host "all $script:Passed test(s) passed" -ForegroundColor Green
    exit 0
}
Write-Host "$script:Failed of $($script:Passed + $script:Failed) test(s) failed" -ForegroundColor Red
exit 1
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'scripts\ci-version.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'build.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Invalid build script syntax' }
$base = [string](@($ast.ParamBlock.Parameters | Where-Object {
    $_.Name.VariablePath.UserPath -eq 'Version'
})[0].DefaultValue.SafeGetValue())
$parsedBase = [version]::Parse($base)
$prefix = '{0}.{1}' -f $parsedBase.Major, $parsedBase.Minor

foreach ($number in @(1, 42, 65534)) {
    $actual = & $scriptPath -RunNumber $number
    if ($actual -ne "$prefix.$number") { throw "Unexpected version: $actual" }
    if ($actual.Split('.').Count -ne 3) { throw 'CI version must have exactly three components' }
    if ([version]::Parse($actual).Build -ne $number) { throw 'Invalid EXE build number' }
    Write-Host "PASS numeric EXE/release version: $actual"
}
$first = & $scriptPath -RunNumber 42
$rerun = & $scriptPath -RunNumber 42
$next = & $scriptPath -RunNumber 43
if ($first -ne $rerun -or [version]$next -le [version]$first) { throw 'Version ordering or rerun stability failed' }
Write-Host 'PASS same run retains version; next run increases version'
foreach ($invalid in @(0, -1, 65535)) {
    $rejected = $false
    try { & $scriptPath -RunNumber $invalid | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid build number accepted: $invalid" }
}
Write-Host 'PASS invalid build numbers fail rather than silently falling back'

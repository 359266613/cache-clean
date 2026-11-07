#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65534)]
    [long]$RunNumber
)

$ErrorActionPreference = 'Stop'
$buildPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'build.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($buildPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Cannot read the build version: build.ps1 has syntax errors.' }
$parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Version' })
if ($parameter.Count -ne 1 -or $null -eq $parameter[0].DefaultValue) {
    throw 'build.ps1 must define a default Version.'
}
$baseVersion = [string]$parameter[0].DefaultValue.SafeGetValue()
if ($baseVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw 'The local build version must have three numeric components, for example 1.0.0.'
}
foreach ($component in $baseVersion.Split('.')) {
    if ([long]$component -gt 65534) { throw 'Version components must not exceed 65534.' }
}

# Use the local major/minor prefix and one build number per workflow run.
$parsed = [version]::Parse($baseVersion)
'{0}.{1}.{2}' -f $parsed.Major, $parsed.Minor, $RunNumber

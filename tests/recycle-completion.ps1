#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\cache-core.ps1')
function Write-CacheLog { param([string]$Line) $script:LastLog = $Line; return '' }
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}

# Stub both the query and destructive command; never touch the real recycle bin.
$script:Queries = 0
function Get-RecycleBinStats {
    $script:Queries++
    if ($script:Queries -eq 1) { return @(1000L, 10L) }
    return @(100L, 1L)
}
function Clear-RecycleBin {
    param([switch]$Force)
    $script:ProgressMode = $ProgressPreference
    throw 'Simulated partial Windows recycle failure'
}
$result = @(Invoke-CacheClean -Ids recyclebin)
Assert ($result.Count -eq 1 -and $result[0].Bytes -eq 900 -and $result[0].Files -eq 9) 'Partial deletion still reports released bytes and items'
Assert ($result[0].Failed -eq 1 -and $result[0].Note -like '*Simulated partial*') 'Underlying recycle error is preserved'
Assert ($script:ProgressMode -eq 'SilentlyContinue') 'Suppress host progress UI during recycle command'
Assert ($script:LastLog.Contains("`t") -and $script:LastLog -like '*Simulated partial*') 'Log records actual tabs and failure details'

function Get-RecycleBinStats { return @(0L, 0L) }
function Clear-RecycleBin { throw 'Must not call Windows cleanup for empty bin' }
$empty = @(Invoke-CacheClean -Ids recyclebin)
Assert ($empty[0].Failed -eq 0 -and $empty[0].Bytes -eq 0) 'Already empty bin succeeds without destructive command'

function Get-RecycleBinStats { throw 'Simulated query failure' }
$unknown = @(Invoke-CacheClean -Ids recyclebin)
Assert ($unknown[0].Failed -eq 1 -and $unknown[0].Note -like '*Simulated query failure*') 'Query failure is reported without attempting deletion'

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'cache-clean-gui.ps1'), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'GUI script syntax'
$dialogs = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -eq '[System.Windows.MessageBox]' -and
    $node.Member.Value -eq 'Show' -and $node.Extent.StartLineNumber -gt 30
}, $true))
Assert ($dialogs.Count -ge 6) 'Found operational GUI dialogs'
foreach ($dialog in $dialogs) {
    Assert ($dialog.Arguments[0].Extent.Text -eq '$win') "Dialog owns main window: line $($dialog.Extent.StartLineNumber)"
}
$text = Get-Content (Join-Path $root 'cache-clean-gui.ps1') -Raw -Encoding UTF8
$show = $text.IndexOf('::Show($win, $text,')
$status = $text.LastIndexOf('$script:UI.StatusText.Text =', $show)
Assert ($show -gt 0 -and $status -gt 0 -and ($show - $status) -lt 250) 'Completion status is updated before completion dialog'

#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\cache-core.ps1')
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'cache-clean-gui.ps1'), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'GUI syntax'
$model = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value -match 'public class CacheRow'
}, $true)
Add-Type -TypeDefinition $model.Value
foreach ($name in @('Update-Totals', 'Update-CategoryView', 'Append-Rows', 'Reset-Rows', 'Toggle-AllSelection')) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
[xml]$xml = Get-Content (Join-Path $root 'ui\main.xaml') -Raw -Encoding UTF8
$reader = New-Object Xml.XmlNodeReader $xml
$window = [Windows.Markup.XamlReader]::Load($reader)
try {
    $script:UI = @{}
    foreach ($name in @('Grid', 'ShowMissing', 'TotalText', 'SelectedText', 'BtnSelectAll')) {
        $script:UI[$name] = $window.FindName($name)
    }
    $script:AllRows = @()
    $script:Busy = $false
    $selectAllLabel = [string]$script:UI.BtnSelectAll.Content
    $script:RowList = New-Object 'Collections.ObjectModel.ObservableCollection[CacheRow]'
    $script:RowView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:RowList)
    $script:UI.Grid.ItemsSource = $script:RowView
    Update-CategoryView
    Assert (-not $script:UI.ShowMissing.IsChecked) 'Missing categories are hidden by default'
    Assert (-not $script:UI.BtnSelectAll.IsEnabled) 'No results disables select-all'
    # The translated missing-directory status used by the production scanner.
    $missing = -join ([char[]](0x65e0, 0x6b64, 0x76ee, 0x5f55))
    $rows = @(
        [pscustomobject]@{ Id = 'ready'; StatusText = 'ready'; Bytes = 10; Selected = $true; CanClean = $true },
        [pscustomobject]@{ Id = 'empty'; StatusText = 'empty'; Bytes = 0; CanClean = $true },
        [pscustomobject]@{ Id = 'denied'; StatusText = 'denied'; Bytes = 0; CanClean = $false },
        [pscustomobject]@{ Id = 'missing'; StatusText = $missing; Bytes = 0; CanClean = $false }
    )
    Append-Rows -Data $rows -From 0
    Assert ($script:AllRows.Count -eq 4 -and $script:RowView.Count -eq 3) 'Filter affects view only, not scan results'
    Assert (@($script:RowView | Where-Object Id -eq 'missing').Count -eq 0) 'Missing directory is hidden'
    Assert (@($script:RowView | Where-Object Id -eq 'empty').Count -eq 1) 'Empty directory remains visible'
    Assert (@($script:RowView | Where-Object Id -eq 'denied').Count -eq 1) 'Access-denied category remains visible'
    Assert ($script:UI.SelectedText.Text -match '3/4') 'Footer reports visible and total counts'
    $script:UI.ShowMissing.IsChecked = $true
    Update-CategoryView
    Assert ($script:RowView.Count -eq 4) 'Checkbox can reveal missing categories'
    $script:UI.ShowMissing.IsChecked = $false
    Update-CategoryView
    Assert ($script:RowView.Count -eq 3 -and $script:AllRows[0].Selected) 'Hiding again preserves existing selections'
    Assert ($script:UI.TotalText.Text -eq (Format-Size 10)) 'Selection total is unchanged'
    Toggle-AllSelection
    Assert (@($script:AllRows | Where-Object Selected).Count -eq 2) 'Select-all selects only cleanable categories'
    Assert ($script:UI.BtnSelectAll.Content -ne $selectAllLabel) 'All selected switches label to clear-all'
    $script:AllRows[1].Selected = $false
    Assert ($script:UI.BtnSelectAll.Content -eq $selectAllLabel) 'Manual deselection immediately restores select-all label'
    Toggle-AllSelection
    Toggle-AllSelection
    Assert (@($script:AllRows | Where-Object Selected).Count -eq 0) 'Second click clears all selections'
    Assert ($script:UI.BtnSelectAll.Content -eq $selectAllLabel) 'No selection restores select-all label'
    $script:Busy = $true
    Update-Totals
    Toggle-AllSelection
    Assert (-not $script:UI.BtnSelectAll.IsEnabled -and @($script:AllRows | Where-Object Selected).Count -eq 0) 'Busy state disables selection changes'
    $script:Busy = $false
    Reset-Rows
    Assert ($script:RowView.Count -eq 0 -and $script:AllRows.Count -eq 0) 'Rescan clears both source and view'
    Append-Rows -Data @($rows[3]) -From 0
    Assert ($script:RowView.Count -eq 0 -and $script:AllRows.Count -eq 1) 'Filtering remains active during incremental scan'
    Assert ($null -ne (Get-CacheCategory dev-yarn) -and $null -ne (Get-CacheCategory dev-other)) 'Development categories remain in the core catalog'
} finally { $window.Close() }

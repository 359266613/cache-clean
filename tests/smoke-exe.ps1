#requires -Version 5.1
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CacheWindowCapture {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
}
'@
$root = Split-Path -Parent $PSScriptRoot
if (-not $ExePath) { $ExePath = Join-Path $root 'dist\CacheClean.exe' }
$metadata = [Diagnostics.FileVersionInfo]::GetVersionInfo((Get-Item -LiteralPath $ExePath).FullName)
[xml]$xaml = Get-Content (Join-Path $root 'ui\main.xaml') -Raw -Encoding UTF8
$namespaces = New-Object Xml.XmlNamespaceManager($xaml.NameTable)
$namespaces.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$namespaces.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$developer = $xaml.SelectSingleNode('//w:TextBlock[@x:Name="DeveloperText"]', $namespaces).GetAttribute('Text')
if ([string]::IsNullOrEmpty($metadata.CompanyName) -or -not $developer.EndsWith($metadata.CompanyName)) {
    throw 'EXE developer metadata differs from UI developer'
}
$folder = Join-Path $PSScriptRoot ('standalone-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
$process = $null
try {
    $exe = Join-Path $folder 'CacheClean.exe'
    Copy-Item -LiteralPath $ExePath -Destination $exe
    $process = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $complete = $false
    while ($watch.Elapsed.TotalSeconds -lt 180) {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) { throw "EXE exited: $($process.ExitCode)" }
        $process.Refresh()
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) { continue }
        $window = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::AutomationIdProperty, 'StatusText')
        $status = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
        if ($status) {
            $text = $status.Current.Name
            if ($text -match '\d{2}:\d{2}:\d{2}$') { $complete = $true; break }
        }
    }
    if (-not $complete) { throw 'Standalone scan did not finish within 180 seconds' }
    Write-Host ("PASS standalone EXE scan: {0:N2}s; {1}" -f $watch.Elapsed.TotalSeconds, $text)
    $adminCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'BtnAdmin')
    if (-not $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $adminCondition)) {
        throw 'Administrator button missing'
    }
    Write-Host 'PASS standalone administrator button'
    foreach ($expected in @(
        @{ Id = 'VersionText'; Text = 'v' + $metadata.FileVersion },
        @{ Id = 'DeveloperText'; Text = $developer }
    )) {
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::AutomationIdProperty, $expected.Id)
        $element = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
        if (-not $element -or $element.Current.Name -ne $expected.Text -or $element.Current.IsOffscreen) {
            throw "Missing or incorrect visible UI identity: $($expected.Id)"
        }
        Write-Host "PASS visible $($expected.Id): $($expected.Text)"
    }
    $missingCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ShowMissing')
    $missingControl = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $missingCondition)
    if (-not $missingControl) { throw 'Missing-category checkbox not found' }
    $toggle = $missingControl.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::Off) {
        throw 'Missing categories must be hidden by default'
    }
    $footerCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'SelectedText')
    $footer = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $footerCondition)
    $defaultFooter = $footer.Current.Name
    if ($defaultFooter -notmatch '(\d+)/(\d+)') { throw 'Visible/total category counts not shown' }
    $totalCount = [int]$Matches[2]
    $toggle.Toggle()
    Start-Sleep -Milliseconds 250
    if ($footer.Current.Name -notmatch '(\d+)/(\d+)' -or [int]$Matches[1] -ne $totalCount -or [int]$Matches[2] -ne $totalCount) {
        throw 'Showing missing categories did not reveal all scanned categories'
    }
    $toggle.Toggle()
    Start-Sleep -Milliseconds 250
    if ($footer.Current.Name -ne $defaultFooter) { throw 'Hiding missing categories did not preserve totals and selections' }
    Write-Host 'PASS missing-category toggle reveals all results and preserves selection totals'
    $allCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'BtnSelectAll')
    $allButton = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $allCondition)
    $allInvoke = $allButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
    $initialLabel = $allButton.Current.Name
    $allInvoke.Invoke()
    Start-Sleep -Milliseconds 200
    $changedLabel = $allButton.Current.Name
    if ($changedLabel -eq $initialLabel) { throw 'Select-all button did not toggle its label' }
    $allInvoke.Invoke()
    Start-Sleep -Milliseconds 200
    if ($allButton.Current.Name -ne $initialLabel) { throw 'Second click did not restore select-all label' }
    $defaultCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'BtnDefault')
    $defaultButton = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $defaultCondition)
    $defaultButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 200
    if ($footer.Current.Name -ne $defaultFooter) { throw 'Recommended selection did not restore original totals' }
    $cleanCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'BtnClean')
    $cleanButton = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $cleanCondition)
    if ($allButton.Current.BoundingRectangle.Left -ge $defaultButton.Current.BoundingRectangle.Left -or
        $defaultButton.Current.BoundingRectangle.Left -ge $cleanButton.Current.BoundingRectangle.Left) {
        throw 'Toolbar order must be select-all, recommended, clean'
    }
    Write-Host 'PASS select-all/clear-all toggles safely; toolbar order matches requested swap'
    foreach ($viewport in @('default', 'minimum')) {
        if ($viewport -eq 'minimum') {
            $transform = $window.GetCurrentPattern([Windows.Automation.TransformPattern]::Pattern)
            $transform.Resize(920, 620)
            Start-Sleep -Milliseconds 300
        }
        $rect = New-Object CacheWindowCapture+Rect
        if (-not [CacheWindowCapture]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
            throw 'Cannot read window bounds'
        }
        $bitmap = New-Object Drawing.Bitmap(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $dc = $graphics.GetHdc()
        try { $captured = [CacheWindowCapture]::PrintWindow($process.MainWindowHandle, $dc, 2) }
        finally { $graphics.ReleaseHdc($dc); $graphics.Dispose() }
        try {
            if (-not $captured) { throw 'Window capture failed' }
            $captureName = $(if ($viewport -eq 'default') { 'verification.png' } else { 'verification-minimum.png' })
            $bitmap.Save((Join-Path $root "dist\$captureName"), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
    }
    [void]$process.CloseMainWindow()
    if (-not $process.WaitForExit(10000)) { throw 'EXE did not close' }
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $resolved = [IO.Path]::GetFullPath($folder)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\standalone-'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

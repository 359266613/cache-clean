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
        $bitmap.Save((Join-Path $root 'dist\verification.png'), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
    [void]$process.CloseMainWindow()
    if (-not $process.WaitForExit(10000)) { throw 'EXE did not close' }
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $resolved = [IO.Path]::GetFullPath($folder)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\standalone-'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

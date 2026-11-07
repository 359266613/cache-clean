#requires -Version 5.1
<#
.SYNOPSIS
    把 cache-clean 打包成单文件 exe（普通用户双击即用，无需安装 PowerShell 模块）。

.DESCRIPTION
    1. 读取 lib\cache-core.ps1（核心逻辑）、ui\main.xaml（界面）、cache-clean-gui.ps1（界面逻辑）
    2. 合并成一个自包含脚本（核心内联 + XAML 内联）
    3. 用 ps2exe 输出 dist\CacheClean.exe（无控制台窗口、管理员清单关闭、DPI 感知）

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Version 1.2.0
#>
[CmdletBinding()]
param(
    [string]$Version = '1.1.2',
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }

Import-Module ps2exe -ErrorAction Stop

# ps2exe 的 -version 只接受 n / n.n / n.n.n / n.n.n.n，其它写法（如 1.0.0-beta）一律归一化
$normalized = ($Version -replace '^[vV]', '')
$normalized = ($normalized -replace '[^0-9.]', '')
if ($normalized -notmatch '^[0-9]+(\.[0-9]+){0,3}$') { $normalized = '1.0.0' }
if ($normalized -ne $Version) {
    Write-Host ("版本号 {0} 不符合 ps2exe 要求，改用 {1}" -f $Version, $normalized) -ForegroundColor Yellow
}
$Version = $normalized

$corePath = Join-Path $root 'lib\cache-core.ps1'
$uiPath = Join-Path $root 'ui\main.xaml'
$guiPath = Join-Path $root 'cache-clean-gui.ps1'
foreach ($p in @($corePath, $uiPath, $guiPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少文件：$p" }
}

Write-Host "读取源文件…"
$core = Get-Content -LiteralPath $corePath -Raw -Encoding UTF8
$xaml = Get-Content -LiteralPath $uiPath -Raw -Encoding UTF8
$gui = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
$pngPath = Join-Path $root 'clean.png'
if (-not (Test-Path -LiteralPath $pngPath)) { throw '缺少 clean.png' }
Add-Type -AssemblyName System.Drawing
$iconPath = Join-Path $OutDir 'CacheClean.ico'
$source = [Drawing.Image]::FromFile($pngPath)
try {
    $images = @()
    foreach ($size in @(16, 32, 48, 256)) {
        $bitmap = New-Object Drawing.Bitmap($size, $size)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $stream = New-Object IO.MemoryStream
        try {
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $scale = [Math]::Min($size / $source.Width, $size / $source.Height)
            $w = [int]($source.Width * $scale); $h = [int]($source.Height * $scale)
            $graphics.DrawImage($source, [int](($size - $w) / 2), [int](($size - $h) / 2), $w, $h)
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            $images += @{ Size = $size; Data = $stream.ToArray() }
        } finally { $graphics.Dispose(); $bitmap.Dispose(); $stream.Dispose() }
    }
    $writer = New-Object IO.BinaryWriter([IO.File]::Create($iconPath))
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
        $offset = 6 + 16 * $images.Count
        foreach ($image in $images) {
            $dimension = $image.Size % 256
            $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
            $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$image.Data.Length); $writer.Write([uint32]$offset)
            $offset += $image.Data.Length
        }
        foreach ($image in $images) { $writer.Write([byte[]]$image.Data) }
    } finally { $writer.Dispose() }
} finally { $source.Dispose() }

$marker = '#@@BODY@@'
$idx = $gui.IndexOf($marker)
if ($idx -lt 0) { throw 'cache-clean-gui.ps1 缺少 #@@BODY@@ 合并标记' }
$head = $gui.Substring(0, $idx)
$body = $gui.Substring($idx + $marker.Length)

$nl = [Environment]::NewLine
# 单引号 here-string：XAML 里有 $ 或反引号也不会被 PowerShell 解析
# 用 Base64 内联：XAML/核心脚本里都有 here-string 结束符，直接塞 here-string 会把合并结果撑破
$b64Xaml = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xaml))
$b64Core = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($core))
$embedded = '$script:EmbeddedXaml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(' + "'" + $b64Xaml + "'" + '))' + $nl
# 后台线程（runspace）需要独立一份核心逻辑；exe 里没有文件可 dot-source
$embeddedCore = '$script:EmbeddedCore = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(' + "'" + $b64Core + "'" + '))' + $nl
$embeddedIcon = '$script:EmbeddedIcon = ''' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($pngPath)) + '''' + $nl

$merged = $head + $nl + $core + $nl + $embeddedCore + $nl + $embedded + $nl + $embeddedIcon + $nl + $body

$mergedPath = Join-Path $env:TEMP ('cache-clean-build-{0}.ps1' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
[System.IO.File]::WriteAllText($mergedPath, $merged, (New-Object System.Text.UTF8Encoding($true)))
Write-Host ("合并完成：{0}（{1:N1} KB）" -f $mergedPath, ((Get-Item $mergedPath).Length / 1KB))

# 合并结果先做语法检查，避免把坏脚本打进 exe
$errs = $null
$toks = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($mergedPath, [ref]$toks, [ref]$errs)
if ($errs.Count -gt 0) {
    $errs | ForEach-Object { Write-Host ("  第 {0} 行：{1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
    throw '合并后的脚本有语法错误，已中止'
}

$outFile = Join-Path $OutDir 'CacheClean.exe'
if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }

Write-Host "调用 ps2exe 打包…"
$ps2exeArgs = @{
    InputFile   = $mergedPath
    OutputFile  = $outFile
    noConsole   = $true
    STA         = $true
    DPIAware    = $true
    x64         = $true
    iconFile    = $iconPath
    title       = '缓存清理'
    description = 'Windows 缓存清理工具'
    product     = 'Cache Clean'
    company     = 'cache-clean'
    copyright   = 'MIT License'
    version     = $Version
}
Invoke-PS2EXE @ps2exeArgs

if (-not (Test-Path -LiteralPath $outFile)) { throw '没有生成 exe，请检查 ps2exe 输出' }
Remove-Item -LiteralPath $mergedPath -Force -ErrorAction SilentlyContinue

$item = Get-Item -LiteralPath $outFile
$hash = (Get-FileHash -LiteralPath $outFile -Algorithm SHA256).Hash
Write-Host ""
Write-Host ("已生成：{0}" -f $item.FullName) -ForegroundColor Green
Write-Host ("大小：{0:N1} MB   版本：{1}" -f ($item.Length / 1MB), $Version) -ForegroundColor DarkGray
Write-Host ("SHA256：{0}" -f $hash) -ForegroundColor DarkGray

#requires -Version 5.1
<#
.SYNOPSIS
    Windows 本机缓存清理工具（命令行版）。默认只扫描统计，不删任何文件。

.DESCRIPTION
    按分类统计可清理的缓存体积；加 -Execute 才真正删除。
    删除时跳过符号链接/目录联接，占用中的文件跳过并计数，不触碰文档与用户目录。

.EXAMPLE
    .\cache-clean.ps1                       # 只扫描
    .\cache-clean.ps1 -List                 # 列出分类
    .\cache-clean.ps1 -Category dev-npm,dev-pip -Execute
    .\cache-clean.ps1 -Execute -Force
    .\cache-clean.ps1 -IncludeAdmin -Execute
    .\cache-clean.ps1 -Json | Out-File report.json -Encoding utf8
#>
[CmdletBinding()]
param(
    [string[]]$Category,
    [switch]$Execute,
    [switch]$IncludeAdmin,
    [switch]$Force,
    [switch]$List,
    [switch]$Json,
    [switch]$NoLog
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\cache-core.ps1')

$isAdmin = Test-Admin

# ---------------------------------------------------------------- 列出分类
if ($List) {
    Write-Host ""
    Write-Host "  可用分类" -ForegroundColor Cyan
    foreach ($c in (Get-CacheCatalog)) {
        $tags = @()
        if ($c.Default) { $tags += '默认' }
        if ($c.Admin) { $tags += '需管理员' }
        $tagText = if ($tags.Count -gt 0) { '(' + ($tags -join '/') + ')' } else { '' }
        Write-Host ("  {0,-16} {1} {2}" -f $c.Id, $c.Label, $tagText) -ForegroundColor White
        Write-Host ("  {0,-16} {1}" -f '', $c.Note) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  界面版：双击 cache-clean.cmd" -ForegroundColor DarkGray
    Write-Host ""
    return
}

# ---------------------------------------------------------------- 选分类
$ids = @()
if ($Category -and $Category.Count -gt 0) {
    foreach ($raw in $Category) {
        foreach ($one in ($raw -split ',')) {
            $id = $one.Trim()
            if (-not $id) { continue }
            if (-not (Get-CacheCategory -Id $id)) {
                Write-Host ("  未知分类：{0}" -f $id) -ForegroundColor Red
                Write-Host ("  可用：{0}" -f ((Get-CacheCatalog | ForEach-Object { $_.Id }) -join ', ')) -ForegroundColor DarkGray
                exit 2
            }
            $ids += $id
        }
    }
} else {
    foreach ($c in (Get-CacheCatalog)) {
        if ($c.Admin -and -not $IncludeAdmin) { continue }
        if (-not $c.Default -and -not $IncludeAdmin) { continue }
        $ids += $c.Id
    }
}
$ids = $ids | Select-Object -Unique

if ($ids.Count -eq 0) {
    Write-Host "  没有匹配的分类，用 -List 查看可用项。" -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------- 扫描
Write-Host ""
Write-Host "  缓存清理 · 扫描" -ForegroundColor Cyan
Write-Host ("  管理员：{0}    模式：{1}" -f $(if ($isAdmin) { '是' } else { '否（需管理员的分类会跳过）' }), $(if ($Execute) { '清理' } else { '仅统计（加 -Execute 才删除）' })) -ForegroundColor DarkGray
Write-Host ""

$rows = Invoke-CacheScan -State $null -Ids $ids
$totalBytes = [double]0
$totalFiles = 0
foreach ($r in $rows) {
    $totalBytes += $r.Bytes
    $totalFiles += $r.Files
    Write-Host ("  {0}  {1}" -f $r.Label, $r.SizeText) -ForegroundColor White
    Write-Host ("      {0} 个文件 · {1} · {2}" -f $r.FilesText, $r.LocText, $r.StatusText) -ForegroundColor DarkGray
    if ($r.Note) { Write-Host ("      " + $r.Note) -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host ("  合计可释放：{0}   （{1} 个文件）" -f (Format-Size -Bytes $totalBytes), $totalFiles.ToString('N0')) -ForegroundColor Green
Write-Host ""

if ($Json) {
    $rows | Select-Object Id, Label, Bytes, Files, StatusText, Paths | ConvertTo-Json -Depth 3
    return
}

if (-not $Execute) {
    Write-Host "  这只是统计。确认要删时加 -Execute，例如：" -ForegroundColor Yellow
    Write-Host "    .\cache-clean.ps1 -Execute" -ForegroundColor DarkGray
    Write-Host "    .\cache-clean.ps1 -Category dev-npm,dev-pip -Execute" -ForegroundColor DarkGray
    Write-Host ""
    return
}

$cleanable = @($rows | Where-Object { $_.CanClean -and ($_.Kind -eq 'recyclebin' -or $_.Paths.Count -gt 0) })
if ($cleanable.Count -eq 0) {
    Write-Host "  没有可清理的内容。" -ForegroundColor Yellow
    return
}

if (-not $Force) {
    $answer = Read-Host "  确认删除以上内容？输入 y 继续"
    if ($answer -notmatch '^[yY]') {
        Write-Host "  已取消，未删除任何文件。" -ForegroundColor Yellow
        return
    }
}

# ---------------------------------------------------------------- 执行清理
Write-Host ""
Write-Host "  正在清理…" -ForegroundColor Cyan

$results = Invoke-CacheClean -State $null -Ids @($cleanable | ForEach-Object { $_.Id })

$okBytes = [double]0
$okFiles = 0
$failedTotal = 0
Write-Host ""
foreach ($res in $results) {
    $okBytes += $res.Bytes
    $okFiles += $res.Files
    $failedTotal += $res.Failed
    Write-Host ("  {0}：释放 {1}，{2} 个文件  {3:N1}s" -f $res.Label, $res.SizeText, $res.Files.ToString('N0'), $res.Seconds) -ForegroundColor White
    if ($res.Note) { Write-Host ("      " + $res.Note) -ForegroundColor DarkGray }
    if ($res.Failed -gt 0) { Write-Host ("      跳过 {0} 项（被占用或无权限）" -f $res.Failed) -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host ("  已释放：{0}   （{1} 个文件，跳过 {2} 项）" -f (Format-Size -Bytes $okBytes), $okFiles.ToString('N0'), $failedTotal) -ForegroundColor Green
if (-not $NoLog) { Write-Host ("  日志：{0}" -f (Join-Path $env:LOCALAPPDATA 'cache-clean\logs')) -ForegroundColor DarkGray }
Write-Host ""

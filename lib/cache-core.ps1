# cache-core.ps1 —— 分类定义、扫描与清理逻辑（CLI 与 GUI 共用）
# 约定：只接受白名单分类里的路径；删除时跳过符号链接/联接点，占用文件跳过并计数。

# 纯托管加速：PowerShell 逐文件循环太慢（7 万文件约 7 秒），这里用 C# 走同样的安全规则
if (-not ('CacheFsScan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;

public static class CacheFsScan
{
    public static long Measure(string root, out long files, out long failed)
    {
        files = 0; failed = 0; long bytes = 0;
        var stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            string cur = stack.Pop();
            DirectoryInfo di;
            try { di = new DirectoryInfo(cur); if (!di.Exists) continue; }
            catch { failed++; continue; }
            try
            {
                foreach (var fi in di.EnumerateFiles())
                {
                    try { bytes += fi.Length; files++; }
                    catch { failed++; }
                }
            }
            catch { failed++; }
            try
            {
                foreach (var sd in di.EnumerateDirectories())
                {
                    try { if ((sd.Attributes & FileAttributes.ReparsePoint) != 0) continue; }
                    catch { continue; }
                    stack.Push(sd.FullName);
                }
            }
            catch { failed++; }
        }
        return bytes;
    }

    public static long Remove(string path, out long files, out long failed)
    {
        files = 0; failed = 0; long bytes = 0;
        try
        {
            var fsi = new FileInfo(path);
            if ((fsi.Attributes & FileAttributes.ReparsePoint) != 0) return 0;
        }
        catch { failed++; return 0; }
        RemoveAny(new DirectoryInfo(path), ref bytes, ref files, ref failed);
        return bytes;
    }

    private static void RemoveAny(DirectoryInfo di, ref long bytes, ref long files, ref long failed)
    {
        if (!di.Exists)
        {
            var fi = new FileInfo(di.FullName);
            try
            {
                long l = fi.Length;
                fi.Delete();
                bytes += l; files++;
            }
            catch { failed++; }
            return;
        }
        try
        {
            foreach (var f in di.EnumerateFiles())
            {
                try
                {
                    long l = f.Length;
                    f.Delete();
                    bytes += l; files++;
                }
                catch { failed++; }
            }
        }
        catch { failed++; }
        try
        {
            foreach (var sd in di.EnumerateDirectories())
            {
                try { if ((sd.Attributes & FileAttributes.ReparsePoint) != 0) continue; }
                catch { continue; }
                RemoveAny(sd, ref bytes, ref files, ref failed);
            }
        }
        catch { failed++; }
        try { Directory.Delete(di.FullName, false); }
        catch { }
    }
}
'@
}

$script:CacheCatalog = @(
    [pscustomobject]@{
        Id = 'temp-user'; Label = '用户临时文件'; Default = $true; Admin = $false; Kind = 'dir'
        Note = '%TEMP% 下的安装/解压残留；占用中的文件会自动跳过'
        Paths = @('%TEMP%', '%LOCALAPPDATA%\Temp')
    }
    [pscustomobject]@{
        Id = 'crash-dumps'; Label = '崩溃转储'; Default = $true; Admin = $false; Kind = 'dir'
        Note = '应用崩溃留下的 dmp 文件，一般不需要保留'
        Paths = @('%LOCALAPPDATA%\CrashDumps')
    }
    [pscustomobject]@{
        Id = 'thumbnails'; Label = '缩略图缓存'; Default = $true; Admin = $false; Kind = 'files'
        Note = '资源管理器缩略图与图标数据库，删除后自动重建'
        Paths = @('%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db',
                  '%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache_*.db')
    }
    [pscustomobject]@{
        Id = 'dev-npm'; Label = 'npm 缓存'; Default = $true; Admin = $false; Kind = 'dir'
        Note = 'npm 下载缓存与 npx 临时安装，删除后下次安装重新下载'
        Paths = @('%LOCALAPPDATA%\npm-cache\_cacache', '%LOCALAPPDATA%\npm-cache\_npx',
                  '%USERPROFILE%\.npm\_cacache', '%USERPROFILE%\.npm\_npx')
    }
    [pscustomobject]@{
        Id = 'dev-pnpm'; Label = 'pnpm 存储'; Default = $true; Admin = $false; Kind = 'dir'
        Note = '全局 store 与元数据缓存；已装项目的硬链接不受影响'
        Paths = @('%LOCALAPPDATA%\pnpm\store', '%LOCALAPPDATA%\pnpm-cache', '%USERPROFILE%\.pnpm-store')
    }
    [pscustomobject]@{
        Id = 'dev-pip'; Label = 'pip 缓存'; Default = $true; Admin = $false; Kind = 'dir'
        Note = 'wheel 与 http 缓存，删除后重装 Python 包会重新下载'
        Paths = @('%LOCALAPPDATA%\pip\cache')
    }
    [pscustomobject]@{
        Id = 'dev-yarn'; Label = 'Yarn 缓存'; Default = $true; Admin = $false; Kind = 'dir'
        Note = 'Yarn 1 与 berry 缓存'
        Paths = @('%LOCALAPPDATA%\Yarn\Cache', '%LOCALAPPDATA%\Yarn\berry\cache')
    }
    [pscustomobject]@{
        Id = 'dev-other'; Label = '其它开发缓存'; Default = $true; Admin = $false; Kind = 'dir'
        Note = 'go-build、cargo、gradle 缓存'
        Paths = @('%LOCALAPPDATA%\go-build', '%USERPROFILE%\go\pkg\mod\cache',
                  '%USERPROFILE%\.cargo\registry\cache', '%USERPROFILE%\.gradle\caches')
    }
    [pscustomobject]@{
        Id = 'browser'; Label = '浏览器缓存'; Default = $false; Admin = $false; Kind = 'dir'
        Note = 'Edge / Chrome / Firefox 缓存；建议先完全退出浏览器再清'
        Paths = @('%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache',
                  '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache',
                  '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache',
                  '%LOCALAPPDATA%\Microsoft\Edge\User Data\Service Worker\CacheStorage',
                  '%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache',
                  '%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache',
                  '%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache',
                  '%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2')
    }
    [pscustomobject]@{
        Id = 'recyclebin'; Label = '回收站'; Default = $false; Admin = $false; Kind = 'recyclebin'
        Note = '清空回收站，删除后不可恢复，请先确认'
        Paths = @()
    }
    [pscustomobject]@{
        Id = 'windows-temp'; Label = '系统临时文件'; Default = $false; Admin = $true; Kind = 'dir'
        Note = 'C:\Windows\Temp，需要管理员权限'
        Paths = @('%SystemRoot%\Temp')
    }
    [pscustomobject]@{
        Id = 'windows-update'; Label = 'Windows 更新缓存'; Default = $false; Admin = $true; Kind = 'dir'
        Note = 'SoftwareDistribution\Download；清理时临时停止 wuauserv'
        Paths = @('%SystemRoot%\SoftwareDistribution\Download')
        Service = 'wuauserv'
    }
)

function Get-CacheCatalog { return $script:CacheCatalog }

function Get-CacheCategory {
    param([string]$Id)
    return ($script:CacheCatalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# 兜底护栏：整盘、用户主目录、桌面/文档/下载、Windows 目录一律拒绝
function Test-SafeTarget {
    param([string]$Path)
    if (-not $Path) { return $false }
    $p = ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\')
    $blocked = New-Object 'System.Collections.Generic.HashSet[string]'
    $cands = @(
        [System.IO.Path]::GetPathRoot($p),
        [Environment]::GetFolderPath('UserProfile'),
        [Environment]::GetFolderPath('LocalApplicationData'),
        [Environment]::GetFolderPath('ApplicationData'),
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32')
    )
    foreach ($c in $cands) {
        if (-not $c) { continue }
        try { [void]$blocked.Add(([System.IO.Path]::GetFullPath($c)).TrimEnd('\')) } catch { }
    }
    if ($blocked.Contains($p)) { return $false }
    if ($p.Length -lt 8) { return $false }
    return $true
}

function Resolve-Target {
    param([string]$Pattern)
    $p = [Environment]::ExpandEnvironmentVariables($Pattern)
    if ($p -match '[*?]') {
        foreach ($h in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) { $h.FullName }
        return
    }
    if (Test-Path -LiteralPath $p) {
        try { (Get-Item -LiteralPath $p -Force).FullName } catch { }
    }
}

# 列出分类的有效目标；$Seen 用于跨分类去重（%TEMP% 常与 LocalAppData\Temp 相同）
function Get-CategoryTargets {
    param($Cat, $Seen)
    $out = @()
    if ($Cat.Kind -eq 'recyclebin') { return $out }
    foreach ($pat in $Cat.Paths) {
        foreach ($t in @(Resolve-Target -Pattern $pat)) {
            $key = $t.ToLowerInvariant()
            try { $key = ([System.IO.Path]::GetFullPath($t)).ToLowerInvariant() } catch { }
            if ($Seen) { if (-not $Seen.Add($key)) { continue } }
            if (-not (Test-SafeTarget -Path $t)) { continue }
            $out += $t
        }
    }
    return $out
}

# 统计体积：跳过 reparse point，不跟随链接
function Get-TreeStats {
    param([string]$Root)

    if ('CacheFsScan' -as [type]) {
        $f = [long]0
        $x = [long]0
        try {
            $bytes = [CacheFsScan]::Measure($Root, [ref]$f, [ref]$x)
            return @{ Bytes = [double]$bytes; Files = $f; Dirs = 0; Failed = $x }
        } catch { }
    }

    $s = @{ Bytes = [double]0; Files = 0; Dirs = 0; Failed = 0 }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    $rp = [System.IO.FileAttributes]::ReparsePoint
    while ($stack.Count -gt 0) {
        $cur = [string]$stack.Pop()
        $di = [System.IO.DirectoryInfo]::new($cur)
        if (-not $di.Exists) { continue }
        $s.Dirs++
        try {
            foreach ($fi in $di.EnumerateFiles()) {
                try { $s.Bytes += $fi.Length; $s.Files++ } catch { $s.Failed++ }
            }
        } catch { $s.Failed++ }
        try {
            foreach ($sd in $di.EnumerateDirectories()) {
                try {
                    if (($sd.Attributes -band $rp) -ne 0) { continue }
                } catch { continue }
                $stack.Push($sd.FullName)
            }
        } catch { $s.Failed++ }
    }
    return $s
}

function Remove-Tree {
    param([string]$Path, $Stats)
    $rp = [System.IO.FileAttributes]::ReparsePoint
    $attr = 0
    try { $attr = [System.IO.File]::GetAttributes($Path) } catch { $Stats.Failed++; return }
    if (($attr -band $rp) -ne 0) { return }

    if (($attr -band [System.IO.FileAttributes]::Directory) -ne 0) {
        $di = [System.IO.DirectoryInfo]::new($Path)
        try {
            foreach ($fi in $di.EnumerateFiles()) {
                try {
                    $len = $fi.Length
                    $fi.Delete()
                    $Stats.Bytes += $len
                    $Stats.Files++
                } catch { $Stats.Failed++ }
            }
        } catch { $Stats.Failed++ }
        try {
            foreach ($sd in $di.EnumerateDirectories()) {
                try {
                    if (($sd.Attributes -band $rp) -ne 0) { continue }
                } catch { continue }
                Remove-Tree -Path $sd.FullName -Stats $Stats
            }
        } catch { $Stats.Failed++ }
        try { [System.IO.Directory]::Delete($Path, $false) } catch { }
    } else {
        $fi = [System.IO.FileInfo]::new($Path)
        $len = [double]0
        try { $len = $fi.Length } catch { }
        try {
            $fi.Delete()
            $Stats.Bytes += $len
            $Stats.Files++
        } catch { $Stats.Failed++ }
    }
}

function Clear-DirectoryContents {
    param([string]$Root, $Stats)
    $children = @()
    try { $children = [System.IO.Directory]::GetFileSystemEntries($Root) } catch { $Stats.Failed++; return }

    if ('CacheFsScan' -as [type]) {
        foreach ($c in $children) {
            $f = [long]0
            $x = [long]0
            try {
                $b = [CacheFsScan]::Remove($c, [ref]$f, [ref]$x)
                $Stats.Bytes += $b
                $Stats.Files += $f
                $Stats.Failed += $x
            } catch { $Stats.Failed++ }
        }
        return
    }

    foreach ($c in $children) { Remove-Tree -Path $c -Stats $Stats }
}

function Write-CacheLog {
    param([string]$Line)
    $dir = Join-Path $env:LOCALAPPDATA 'cache-clean\logs'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { [void](New-Item -ItemType Directory -Path $dir -Force) } catch { return '' }
    }
    $file = Join-Path $dir ('cache-clean-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try { Add-Content -LiteralPath $file -Value $Line -Encoding UTF8 } catch { }
    return $file
}

# 扫描全部（或指定）分类，返回可直接显示的行对象
function Invoke-CacheScan {
    param([hashtable]$State, [string[]]$Ids)

    $isAdmin = Test-Admin
    $cats = $script:CacheCatalog
    if ($Ids -and $Ids.Count -gt 0) {
        $cats = @($cats | Where-Object { $Ids -contains $_.Id })
    }
    if ($State) { $State['IsAdmin'] = $isAdmin }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $rows = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($c in $cats) {
        $i++
        if ($State) { $State['Status'] = ('正在统计 {0}（{1}/{2}）' -f $c.Label, $i, $cats.Count) }

        $targets = @()
        if ($c.Kind -ne 'recyclebin') { $targets = @(Get-CategoryTargets -Cat $c -Seen $seen) }

        $bytes = [double]0
        $files = 0
        $sizeText = '—'
        $filesText = '—'
        $locText = '—'

        if ($c.Admin -and -not $isAdmin) {
            $status = '需要管理员'
        } elseif ($c.Kind -eq 'recyclebin') {
            $status = '可清空 · 体积未统计'
        } elseif ($targets.Count -eq 0) {
            $status = '无此目录'
        } else {
            if ($c.Kind -eq 'files') {
                foreach ($t in $targets) {
                    try { $bytes += ([System.IO.FileInfo]$t).Length; $files++ } catch { }
                }
            } else {
                foreach ($t in $targets) {
                    $st = Get-TreeStats -Root $t
                    $bytes += $st.Bytes
                    $files += $st.Files
                }
            }
            $sizeText = Format-Size -Bytes $bytes
            $filesText = $files.ToString('N0')
            $locText = ('{0} 处' -f $targets.Count)
            $status = $(if ($bytes -le 0) { '已为空' } else { '可清理' })
        }

        if ($c.Admin -and -not $isAdmin) {
            $sizeText = '—'; $filesText = '—'
            if ($targets.Count -gt 0) { $locText = ('{0} 处' -f $targets.Count) }
        }

        [void]$rows.Add([pscustomobject]@{
                Id         = $c.Id
                Label      = $c.Label
                Note       = $c.Note
                Kind       = $c.Kind
                Admin      = [bool]$c.Admin
                Default    = [bool]$c.Default
                Bytes      = $bytes
                Files      = $files
                SizeText   = $sizeText
                FilesText  = $filesText
                LocText    = $locText
                StatusText = $status
                CanClean   = [bool](((-not $c.Admin) -or $isAdmin) -and ($c.Kind -eq 'recyclebin' -or $targets.Count -gt 0))
                Paths      = $targets
                PathsText  = ($targets -join [Environment]::NewLine)
                FirstPath  = $(if ($targets.Count -gt 0) { $targets[0] } else { '' })
                Selected   = [bool]($c.Default -and ((-not $c.Admin) -or $isAdmin) -and $targets.Count -gt 0)
            })

        # 每完成一个分类就交给界面刷新，避免大缓存卡在空白列表
        if ($State) {
            $State['Rows'] = @($rows)
            $State['DoneCount'] = $i
            $State['TotalCount'] = $cats.Count
        }
    }

    if ($State) {
        $State['Status'] = '扫描完成'
        $State['Rows'] = @($rows)
        $State['DoneCount'] = $cats.Count
    }
    return @($rows)
}

# 清理指定分类，返回每个分类的结果
function Invoke-CacheClean {
    param([hashtable]$State, [string[]]$Ids)

    $results = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($id in $Ids) {
        $c = Get-CacheCategory -Id $id
        if (-not $c) { continue }
        $i++
        if ($State) { $State['Status'] = ('正在清理 {0}（{1}/{2}）' -f $c.Label, $i, $Ids.Count) }

        $targets = @()
        if ($c.Kind -ne 'recyclebin') { $targets = @(Get-CategoryTargets -Cat $c) }

        $stats = @{ Bytes = [double]0; Files = 0; Failed = 0 }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        if ($c.Kind -eq 'recyclebin') {
            try { Clear-RecycleBin -Force -ErrorAction Stop } catch { $stats.Failed++ }
        } elseif ($c.Kind -eq 'files') {
            foreach ($t in $targets) {
                $len = [double]0
                try { $len = ([System.IO.FileInfo]$t).Length } catch { }
                try {
                    [System.IO.File]::Delete($t)
                    $stats.Bytes += $len
                    $stats.Files++
                } catch { $stats.Failed++ }
            }
        } else {
            $service = $c.Service
            $stopped = $false
            if ($service) {
                try {
                    Stop-Service -Name $service -Force -ErrorAction Stop
                    $stopped = $true
                } catch {
                    $sw.Stop()
                    [void]$results.Add([pscustomobject]@{
                            Id = $c.Id; Label = $c.Label; Bytes = [double]0; Files = 0; Failed = 1
                            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); SizeText = '0 B'
                            Note = ('无法停止服务 {0}，已跳过' -f $service)
                        })
                    continue
                }
            }
            try {
                foreach ($t in $targets) { Clear-DirectoryContents -Root $t -Stats $stats }
            } finally {
                if ($stopped) { try { Start-Service -Name $service -ErrorAction SilentlyContinue } catch { } }
            }
        }

        $sw.Stop()
        [void]$results.Add([pscustomobject]@{
                Id      = $c.Id
                Label   = $c.Label
                Bytes   = $stats.Bytes
                Files   = $stats.Files
                Failed  = $stats.Failed
                Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                SizeText = (Format-Size -Bytes $stats.Bytes)
                Note    = ''
            })
        [void](Write-CacheLog ('{0}`t{1}`t{2} 个文件`t失败 {3}`t{4}' -f (Get-Date -Format 's'), $c.Id, $stats.Files, $stats.Failed, (Format-Size -Bytes $stats.Bytes)))
    }

    if ($State) { $State['Status'] = '清理完成' }
    return @($results)
}

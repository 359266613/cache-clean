#requires -Version 5.1
<#
    缓存清理 · 界面版
    双击 cache-clean.cmd 启动。扫描在后台线程执行，界面不卡。
#>
[CmdletBinding()]
param()

#@@BODY@@
$ErrorActionPreference = 'Stop'

# 隐藏窗口启动时错误不可见，统一落日志并弹窗
trap {
    $msg = $_.Exception.Message
    $pos = ''
    try { $pos = $_.InvocationInfo.PositionMessage } catch { }
    $full = ('{0:yyyy-MM-dd HH:mm:ss} {1}{2}{3}' -f (Get-Date), $msg, [Environment]::NewLine, $pos)
    try {
        $dir = Join-Path $env:LOCALAPPDATA 'cache-clean'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Add-Content -LiteralPath (Join-Path $dir 'gui-error.log') -Value $full -Encoding UTF8
    } catch { }
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [void][System.Windows.MessageBox]::Show($msg, '缓存清理 · 启动失败', 'OK', 'Error')
    } catch { }
    exit 1
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$root = $PSScriptRoot
if (-not $root) {
    try { $root = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { $root = (Get-Location).Path }
}

# 开发态从 lib 加载；打包成 exe 时核心逻辑已内联，函数已在当前作用域
$corePath = Join-Path $root 'lib\cache-core.ps1'
if ($script:EmbeddedCore) {
    $script:CoreText = $script:EmbeddedCore
} elseif (Test-Path -LiteralPath $corePath) {
    . $corePath
    $script:CoreText = Get-Content -LiteralPath $corePath -Raw -Encoding UTF8
} else {
    throw '找不到核心脚本 lib\cache-core.ps1'
}

# ------------------------------------------------------------------ 行模型
if (-not ('CacheRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
public class CacheRow : INotifyPropertyChanged {
    public string Id { get; set; }
    public string Label { get; set; }
    public string Note { get; set; }
    public string Kind { get; set; }
    public string SizeText { get; set; }
    public string FilesText { get; set; }
    public string LocText { get; set; }
    public string StatusText { get; set; }
    public string PathsText { get; set; }
    public string FirstPath { get; set; }
    public bool CanClean { get; set; }
    public bool IsDefault { get; set; }
    public bool IsMissing { get; set; }
    public double Bytes { get; set; }
    private bool _selected;
    public bool Selected {
        get { return _selected; }
        set { if (_selected != value) { _selected = value; Raise("Selected"); } }
    }
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string n) {
        var h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(n));
    }
}
'@
}

# ------------------------------------------------------------------ 载入界面
$uiPath = Join-Path $root 'ui\main.xaml'
if ($script:EmbeddedXaml) {
    $xamlText = $script:EmbeddedXaml
} elseif (Test-Path -LiteralPath $uiPath) {
    $xamlText = Get-Content -LiteralPath $uiPath -Raw -Encoding UTF8
} else {
    throw '找不到界面定义 ui\main.xaml'
}
[xml]$uiXml = $xamlText
$nodeReader = New-Object System.Xml.XmlNodeReader $uiXml
$win = [Windows.Markup.XamlReader]::Load($nodeReader)
$appVersion = '开发版'
if ($script:EmbeddedVersion) {
    $appVersion = 'v' + $script:EmbeddedVersion
} else {
    $buildPath = Join-Path $root 'build.ps1'
    if (Test-Path -LiteralPath $buildPath) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($buildPath, [ref]$tokens, [ref]$errors)
        $versionParam = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Version' })
        if ($errors.Count -eq 0 -and $versionParam.Count -eq 1 -and $versionParam[0].DefaultValue) {
            $appVersion = 'v' + [string]$versionParam[0].DefaultValue.SafeGetValue()
        }
    }
}
$win.FindName('VersionText').Text = $appVersion
$win.Title = '缓存清理 ' + $appVersion
$iconStream = $null
try {
    if ($script:EmbeddedIcon) {
        $iconStream = [IO.MemoryStream]::new([Convert]::FromBase64String($script:EmbeddedIcon))
    } elseif (Test-Path -LiteralPath (Join-Path $root 'clean.png')) {
        $iconStream = [IO.File]::OpenRead((Join-Path $root 'clean.png'))
    }
    if ($iconStream) {
        $icon = New-Object Windows.Media.Imaging.BitmapImage
        $icon.BeginInit()
        $icon.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $icon.StreamSource = $iconStream
        $icon.EndInit()
        $icon.Freeze()
        $win.Icon = $icon
    }
} finally { if ($iconStream) { $iconStream.Dispose() } }

$script:UI = @{
    Grid        = $win.FindName('Grid')
    TotalText   = $win.FindName('TotalText')
    SelectedText= $win.FindName('SelectedText')
    StatusText  = $win.FindName('StatusText')
    Progress    = $win.FindName('Progress')
    PathBox     = $win.FindName('PathBox')
    PathHint    = $win.FindName('PathHint')
    AdminBadge  = $win.FindName('AdminBadge')
    AdminBadgeText = $win.FindName('AdminBadgeText')
    BtnScan     = $win.FindName('BtnScan')
    BtnClean    = $win.FindName('BtnClean')
    BtnDefault  = $win.FindName('BtnDefault')
    BtnSelectAll = $win.FindName('BtnSelectAll')
    BtnOpenPath = $win.FindName('BtnOpenPath')
    BtnLogs     = $win.FindName('BtnLogs')
    BtnAdmin    = $win.FindName('BtnAdmin')
    ShowMissing = $win.FindName('ShowMissing')
}
$script:UI.BtnAdmin.Visibility = $(if (Test-Admin) { 'Collapsed' } else { 'Visible' })

$script:AllRows = @()
$script:Job = $null
$script:Busy = $false
$script:AppliedCount = 0
$script:RowList = New-Object 'System.Collections.ObjectModel.ObservableCollection[CacheRow]'
$script:RowView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:RowList)
$script:UI.Grid.ItemsSource = $script:RowView

# 扫描/清理共用的后台状态
$script:Sync = [hashtable]::Synchronized(@{
        Phase   = 'idle'
        Status  = ''
        Done    = $true
        Rows    = @()
        Results = @()
        Ids     = @()
        Error   = ''
        IsAdmin = $false
        CoreText = ''
    })

# ------------------------------------------------------------------ 逻辑
function Set-Busy {
    param([bool]$On, [string]$Text)
    $script:Busy = $On
    $script:UI.BtnScan.IsEnabled = -not $On
    $script:UI.BtnClean.IsEnabled = -not $On
    $script:UI.BtnDefault.IsEnabled = -not $On
    $script:UI.BtnAdmin.IsEnabled = -not $On
    $script:UI.ShowMissing.IsEnabled = -not ($On -and $script:Sync.Phase -eq 'clean')
    # 扫描时允许浏览已完成的行（只是暂时不能清理）；清理时锁表避免删到正在统计的目录
    $script:UI.Grid.IsEnabled = -not ($On -and $script:Sync.Phase -eq 'clean')
    $script:UI.Progress.Visibility = $(if ($On) { 'Visible' } else { 'Hidden' })
    $script:UI.Progress.IsIndeterminate = $On
    if ($Text) { $script:UI.StatusText.Text = $Text }
    Update-Totals
}

function Update-Totals {
    $sum = [double]0
    $count = 0
    $available = 0
    $selectedAvailable = 0
    foreach ($r in $script:AllRows) {
        if ($r.CanClean) {
            $available++
            if ($r.Selected) { $selectedAvailable++ }
        }
        if ($r.Selected) { $sum += $r.Bytes; $count++ }
    }
    $script:UI.TotalText.Text = Format-Size -Bytes $sum
    $script:UI.SelectedText.Text = ('已选 {0} 项 · 显示 {1}/{2} 项' -f $count, $script:RowView.Count, $script:AllRows.Count)
    $script:UI.BtnSelectAll.Content = $(if ($available -gt 0 -and $selectedAvailable -eq $available) { '全部取消' } else { '全部选中' })
    $script:UI.BtnSelectAll.IsEnabled = (-not $script:Busy -and $available -gt 0)
}

function Toggle-AllSelection {
    if ($script:Busy) { return }
    $selectAll = @($script:AllRows | Where-Object { $_.CanClean -and -not $_.Selected }).Count -gt 0
    foreach ($r in $script:AllRows) { $r.Selected = ($selectAll -and $r.CanClean) }
    Update-Totals
}

function Update-CategoryView {
    $script:RowView.Filter = [Predicate[object]]{
        param($row)
        return ([bool]$script:UI.ShowMissing.IsChecked -or -not $row.IsMissing)
    }
    Update-Totals
}

function Start-CacheJob {
    param([string]$Phase, [string[]]$Ids)

    $script:Sync.Phase = $Phase
    $script:Sync.Done = $false
    $script:Sync.Error = ''
    $script:Sync.Rows = @()
    $script:Sync.Results = @()
    $script:Sync.Ids = $Ids
    $script:Sync.Status = $(if ($Phase -eq 'scan') { '正在扫描…' } else { '正在清理…' })
    $script:Sync.DoneCount = 0
    $script:Sync.TotalCount = 0
    $script:Sync.CoreText = [string]$script:CoreText
    $script:AppliedCount = 0
    $script:JobWatch = [Diagnostics.Stopwatch]::StartNew()

    if ($Phase -eq 'scan') {
        $script:UI.TotalText.Text = '…'
        Reset-Rows
    }

    Set-Busy -On $true -Text $script:Sync.Status

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    $body = {
        param($State, $Core)
        try {
            if ($State.CoreText) { Invoke-Expression $State.CoreText }
            elseif ($Core -and (Test-Path -LiteralPath $Core)) { . $Core }
            else { throw '后台线程缺少核心脚本' }
            if ($State.Phase -eq 'scan') {
                $State.Rows = @(Invoke-CacheScan -State $State)
            } else {
                $State.Results = @(Invoke-CacheClean -State $State -Ids $State.Ids)
            }
        } catch {
            $State.Error = $_.Exception.Message
        } finally {
            $State.Done = $true
        }
    }

    [void]$ps.AddScript($body).AddParameter('State', $script:Sync).AddParameter('Core', $corePath)
    $script:Job = $ps
    $script:JobHandle = $ps.BeginInvoke()
    $script:JobRunspace = $rs
}

function Reset-Rows {
    $script:AllRows = @()
    if ($script:RowList) { $script:RowList.Clear() }
    Update-Totals
}

# 只追加新完成的分类，保留已有行的勾选与滚动位置
function Append-Rows {
    param($Data, [int]$From)

    $all = @($Data)
    for ($i = $From; $i -lt $all.Count; $i++) {
        $r = $all[$i]
        $row = New-Object CacheRow
        $row.Id = [string]$r.Id
        $row.Label = [string]$r.Label
        $row.Note = [string]$r.Note
        $row.Kind = [string]$r.Kind
        $row.SizeText = [string]$r.SizeText
        $row.FilesText = [string]$r.FilesText
        $row.LocText = [string]$r.LocText
        $row.StatusText = [string]$r.StatusText
        $row.PathsText = [string]$r.PathsText
        $row.FirstPath = [string]$r.FirstPath
        $row.CanClean = [bool]$r.CanClean
        $row.IsDefault = [bool]$r.Default
        $row.IsMissing = ($r.StatusText -eq '无此目录')
        $row.Bytes = [double]$r.Bytes
        $row.Selected = [bool]$r.Selected
        $row.Add_PropertyChanged({ Update-Totals })
        [void]$script:RowList.Add($row)
        $script:AllRows += $row
    }
    Update-Totals
}

function Start-Scan {
    if ($script:Busy) { return }
    $script:UI.PathBox.Text = ''
    $script:UI.PathHint.Text = '选中上方任意一行查看具体目录'
    Start-CacheJob -Phase 'scan' -Ids @()
}

function Show-Detail {
    $row = $script:UI.Grid.SelectedItem
    if (-not $row) {
        $script:UI.PathBox.Text = ''
        $script:UI.PathHint.Text = '选中上方任意一行查看具体目录'
        return
    }
    if ($row.PathsText) {
        $script:UI.PathBox.Text = $row.PathsText
        $script:UI.PathHint.Text = ('{0} · {1}' -f $row.Label, $row.StatusText)
    } else {
        $script:UI.PathBox.Text = ''
        $script:UI.PathHint.Text = ('{0} · {1}' -f $row.Label, $row.StatusText)
    }
}

# ------------------------------------------------------------------ 事件
Update-CategoryView
$script:UI.ShowMissing.Add_Checked({ Update-CategoryView })
$script:UI.ShowMissing.Add_Unchecked({ Update-CategoryView })
$script:UI.BtnScan.Add_Click({ Start-Scan })
$script:UI.BtnAdmin.Add_Click({
    if ($script:Busy) { return }
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ([IO.Path]::GetFileName($exe) -ieq 'powershell.exe') {
            $args = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'cache-clean-gui.ps1')
            Start-Process -FilePath $exe -ArgumentList $args -Verb RunAs -WindowStyle Hidden -ErrorAction Stop
        } else {
            Start-Process -FilePath $exe -Verb RunAs -WindowStyle Hidden -ErrorAction Stop
        }
        $win.Close()
    } catch {
        $script:UI.StatusText.Text = '未完成管理员启动：' + $_.Exception.Message
    }
})
$script:UI.BtnDefault.Add_Click({
        foreach ($r in $script:AllRows) { $r.Selected = ($r.IsDefault -and $r.CanClean) }
    })
$script:UI.BtnSelectAll.Add_Click({ Toggle-AllSelection })
$script:UI.BtnOpenPath.Add_Click({
        $row = $script:UI.Grid.SelectedItem
        if ($row -and $row.FirstPath) {
            try { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $row.FirstPath) } catch { }
        } elseif ($row -and $row.Kind -eq 'recyclebin') {
            Start-Process explorer.exe -ArgumentList 'shell:RecycleBinFolder'
        } elseif ($row) {
            [void][System.Windows.MessageBox]::Show($win, '这个分类没有可用目录（可能不存在或需要管理员）。', '缓存清理', 'OK', 'Information')
        }
    })
$script:UI.BtnLogs.Add_Click({
        $dir = Join-Path $env:LOCALAPPDATA 'cache-clean\logs'
        try {
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            Start-Process explorer.exe -ArgumentList ('"{0}"' -f $dir)
        } catch { }
    })
$script:UI.Grid.Add_SelectionChanged({ Show-Detail })
$script:UI.Grid.Add_MouseDoubleClick({
        $row = $script:UI.Grid.SelectedItem
        if ($row -and $row.FirstPath) {
            try { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $row.FirstPath) } catch { }
        } elseif ($row -and $row.Kind -eq 'recyclebin') {
            Start-Process explorer.exe -ArgumentList 'shell:RecycleBinFolder'
        }
    })

$script:UI.BtnClean.Add_Click({
        if ($script:Busy) { return }
        $selected = @($script:AllRows | Where-Object { $_.Selected })
        if ($selected.Count -eq 0) {
            [void][System.Windows.MessageBox]::Show($win, '还没有勾选任何分类。可以先点「仅选推荐」。', '缓存清理', 'OK', 'Information')
            return
        }
        $sum = [double]0
        foreach ($s in $selected) { $sum += $s.Bytes }
        $names = ($selected | ForEach-Object { $_.Label }) -join '、'
        if ($names.Length -gt 160) { $names = $names.Substring(0, 160) + '…' }

        $msg = "将清理以下 {0} 项，预计释放 {1}：`n`n{2}`n`n清理后，脚本/软件缓存需要时会重新生成；请确认没有正在运行的相关程序。是否继续？" -f $selected.Count, (Format-Size -Bytes $sum), $names
        $answer = [System.Windows.MessageBox]::Show($win, $msg, '确认清理', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }

        Start-CacheJob -Phase 'clean' -Ids @($selected | ForEach-Object { $_.Id })
    })

# ------------------------------------------------------------------ 轮询后台任务
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:Timer.Add_Tick({
        if ($script:Sync.Phase -eq 'idle') { return }

        if (-not $script:Sync.Done) {
            if ($script:Sync.Phase -eq 'scan') {
                $cnt = @($script:Sync.Rows).Count
                if ($cnt -gt $script:AppliedCount) {
                    Append-Rows -Data $script:Sync.Rows -From $script:AppliedCount
                    $script:AppliedCount = $cnt
                }
                $done = [int]$script:Sync.DoneCount
                $all = [int]$script:Sync.TotalCount
                if ($all -gt 0) {
                    $script:UI.StatusText.Text = ('正在扫描 {0}/{1} · {2}' -f $done, $all, $script:Sync.Status)
                } elseif ($script:Sync.Status) {
                    $script:UI.StatusText.Text = $script:Sync.Status
                }
            } elseif ($script:Sync.Status) {
                $script:UI.StatusText.Text = ('{0} · 已用 {1:N0} 秒' -f $script:Sync.Status, $script:JobWatch.Elapsed.TotalSeconds)
            }
            return
        }

        $phase = $script:Sync.Phase
        # Done is set just before the pipeline exits; wait for its actual completion.
        if (-not $script:JobHandle.IsCompleted) { return }
        try { [void]$script:Job.EndInvoke($script:JobHandle) }
        finally {
            $script:Job.Dispose()
            $script:JobRunspace.Dispose()
            $script:Job = $null
        }
        $script:Sync.Phase = 'idle'
        $err = $script:Sync.Error
        Set-Busy -On $false

        if ($err) {
            $script:UI.StatusText.Text = '出错：' + $err
            [void][System.Windows.MessageBox]::Show($win, ('操作失败：' + $err), '缓存清理', 'OK', 'Error')
            return
        }

        if ($phase -eq 'scan') {
            $isAdmin = [bool]$script:Sync.IsAdmin
            $script:UI.AdminBadgeText.Text = $(if ($isAdmin) { '管理员' } else { '标准权限' })
            $script:UI.AdminBadge.Background = $(if ($isAdmin) { '#E8F5EC' } else { '#FFF4E5' })
            $cnt = @($script:Sync.Rows).Count
            if ($cnt -gt $script:AppliedCount) {
                Append-Rows -Data $script:Sync.Rows -From $script:AppliedCount
                $script:AppliedCount = $cnt
            }
            $script:UI.StatusText.Text = ('扫描完成 · {0} 项 · {1}' -f $cnt, (Get-Date -Format 'HH:mm:ss'))
        } else {
            $total = [double]0
            $files = 0
            $failed = 0
            $lines = New-Object System.Collections.ArrayList
            foreach ($r in @($script:Sync.Results)) {
                $total += [double]$r.Bytes
                $files += [int]$r.Files
                $failed += [int]$r.Failed
                [void]$lines.Add(('  {0}  释放 {1}（{2} 个文件） {3}' -f $r.Label, $r.SizeText, $r.Files, $r.Note))
            }
            $text = "已释放 {0}，共 {1} 个文件。`n`n{2}" -f (Format-Size -Bytes $total), $files.ToString('N0'), ($lines -join "`n")
            if ($failed -gt 0) { $text += ("`n`n有 {0} 项未能完成（占用、权限或服务错误），详见分类结果和日志。" -f $failed) }
            $script:UI.StatusText.Text = ('清理完成 · 已释放 {0} · 未完成 {1} 项' -f (Format-Size -Bytes $total), $failed)
            [void][System.Windows.MessageBox]::Show($win, $text, '清理完成', 'OK', 'Information')
            Start-Scan
        }
    })
$script:Timer.Start()

$win.Add_Loaded({ Start-Scan })
$win.Add_Closing({
        param($s, $e)
        if ($script:Busy) {
            $e.Cancel = $true
            [void][System.Windows.MessageBox]::Show($win, '正在处理，请等待完成后再关闭。', '缓存清理', 'OK', 'Information')
        }
    })

[void]$win.ShowDialog()
$script:Timer.Stop()

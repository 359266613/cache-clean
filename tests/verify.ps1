#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\cache-core.ps1')
function Write-CacheLog { param([string]$Line) return '' }

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}

foreach ($path in @(Join-Path $root 'lib\cache-core.ps1') + @(Join-Path $root 'cache-clean-gui.ps1') + @(Join-Path $root 'build.ps1')) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "Syntax: $([IO.Path]::GetFileName($path))"
}

$fixture = Join-Path $PSScriptRoot ('fixture-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'cache\nested'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'outside'))
try {
    [IO.File]::WriteAllBytes((Join-Path $fixture 'cache\a.bin'), [byte[]]::new(17))
    [IO.File]::WriteAllBytes((Join-Path $fixture 'cache\nested\b.bin'), [byte[]]::new(23))
    [IO.File]::WriteAllBytes((Join-Path $fixture 'outside\keep.bin'), [byte[]]::new(99))
    $cache = Join-Path $fixture 'cache'
    $outside = Join-Path $fixture 'outside'
    [void](New-Item -ItemType Junction -Path (Join-Path $cache 'link') -Target $outside)
    $st = Get-TreeStats $cache
    Assert ($st.Bytes -eq 40 -and $st.Files -eq 2) 'Tree measurement skips junctions'
    Assert (-not (Test-SafeTarget (Join-Path $cache 'link'))) 'Reject junction target'
    Assert (-not (Test-SafeTarget (Join-Path $cache 'link\keep.bin'))) 'Reject junction ancestor'
    Assert (-not (Test-SafeTarget $env:USERPROFILE.ToUpperInvariant())) 'Case-insensitive protected path'
    $cat = [pscustomobject]@{
        Id = 'fixture'; Label = 'Fixture'; Note = ''; Default = $true
        Admin = $false; Kind = 'dir'; Paths = @($cache, $cache.ToUpperInvariant())
    }
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    Assert (@(Get-CategoryTargets $cat $seen).Count -eq 1) 'Deduplicate initially empty HashSet'
    $catalog = $script:CacheCatalog
    $script:CacheCatalog = @($cat)
    $rows = @(Invoke-CacheScan)
    Assert ($rows.Count -eq 1 -and $rows[0].Bytes -eq 40 -and $rows[0].Files -eq 2) 'Queued scanner totals'
    $again = @(Invoke-CacheScan)
    Assert ($again[0].Bytes -eq 40) 'Repeated scan'
    $result = @(Invoke-CacheClean -Ids fixture)
    Assert ($result[0].Bytes -eq 40 -and $result[0].Files -eq 2) 'Fixture-only cleanup totals'
    Assert (Test-Path -LiteralPath (Join-Path $outside 'keep.bin')) 'Cleanup preserves junction destination'
    [IO.File]::WriteAllBytes((Join-Path $cache 'service.bin'), [byte[]]::new(11))
    $cat | Add-Member NoteProperty Service @('fixture-service')
    $script:Restarted = $false
    function Get-Service { param($Name) [pscustomobject]@{ Status = 'Running' } }
    function Stop-Service { param($Name) throw 'Simulated stop failure' }
    function Start-Service { param($Name) $script:Restarted = $true }
    $blocked = @(Invoke-CacheClean -Ids fixture)
    Assert ($blocked.Count -eq 1 -and $blocked[0].Failed -eq 1) 'Service stop failure returns one failure'
    Assert (Test-Path -LiteralPath (Join-Path $cache 'service.bin')) 'Service stop failure prevents deletion'
    Assert $script:Restarted 'Attempts to restore originally running service'
    function Start-Service { param($Name) throw 'Simulated restore failure' }
    $restore = @(Invoke-CacheClean -Ids fixture)
    Assert ($restore[0].Failed -eq 2 -and $restore[0].Note.Length -gt 0) 'Service restore failure is reported'
    function Get-Service { param($Name) [pscustomobject]@{ Status = 'Stopped' } }
    $script:Restarted = $false
    function Start-Service { param($Name) $script:Restarted = $true }
    $alreadyStopped = @(Invoke-CacheClean -Ids fixture)
    Assert ($alreadyStopped[0].Files -eq 1 -and -not $script:Restarted) 'Originally stopped service stays stopped'
    Remove-Item Function:\Get-Service, Function:\Stop-Service, Function:\Start-Service
    $script:CacheCatalog = $catalog
    $rb = [CacheFsScan]::RecycleStats()
    Assert ($rb.Length -eq 2 -and $rb[0] -ge 0 -and $rb[1] -ge 0) 'Native recycle bin query'
    $systemRows = @(Invoke-CacheScan -Ids recyclebin,windows-temp,windows-update)
    $systemRows | Format-Table Id, SizeText, FilesText, StatusText, CanClean
    Assert ($systemRows.Count -eq 3) 'System categories return rows'
    function Test-Admin { return $false }
    $denied = $false
    try { Invoke-CacheClean -Ids windows-temp } catch { $denied = $true }
    Assert $denied 'Core rejects unelevated system cleanup'
    Add-Type -AssemblyName PresentationFramework
    [xml]$xml = Get-Content (Join-Path $root 'ui\main.xaml') -Raw -Encoding UTF8
    $reader = New-Object Xml.XmlNodeReader $xml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    Assert ($null -ne $window.FindName('BtnAdmin')) 'WPF administrator control loads'
    $window.Close()
} finally {
    $script:CacheCatalog = $catalog
    # Remove the junction itself before recursively removing the fixture.
    $junction = Join-Path $fixture 'cache\link'
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    $resolved = [IO.Path]::GetFullPath($fixture)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\fixture-'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

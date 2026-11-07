#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\cache-core.ps1')
function Write-CacheLog { param([string]$Line) return '' }

$fixture = Join-Path $PSScriptRoot ('browser-' + [guid]::NewGuid().ToString('N'))
$originalLocal = $env:LOCALAPPDATA
$originalRoaming = $env:APPDATA
$protected = @{}
$caches = @()
function Add-FixtureFile([string]$Relative, [bool]$Protect) {
    $path = Join-Path $fixture $Relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3, 4, 5))
    if ($Protect) { $protected[$path] = (Get-FileHash -LiteralPath $path).Hash }
    else { $script:caches += $path }
}
try {
    $env:LOCALAPPDATA = Join-Path $fixture 'Local'
    $env:APPDATA = Join-Path $fixture 'Roaming'
    foreach ($vendor in @('Microsoft\Edge', 'Google\Chrome')) {
        $data = "Local\$vendor\User Data"
        Add-FixtureFile "$data\Local State" $true
        foreach ($profile in @('Default', 'Profile 1')) {
            foreach ($cache in @('Cache', 'Code Cache', 'GPUCache')) {
                Add-FixtureFile "$data\$profile\$cache\entry.bin" $false
            }
            foreach ($sensitive in @(
                'Cookies', 'Network\Cookies', 'Login Data', 'Login Data For Account',
                'Web Data', 'Preferences', 'Secure Preferences', 'Bookmarks', 'History',
                'Local Storage\leveldb\record', 'Session Storage\record', 'IndexedDB\record',
                'Sessions\Session_1', 'Local Extension Settings\record',
                'Service Worker\CacheStorage\record', 'Service Worker\Database\record'
            )) {
                Add-FixtureFile "$data\$profile\$sensitive" $true
            }
        }
    }
    Add-FixtureFile 'Local\Mozilla\Firefox\Profiles\test.default\cache2\entries\entry.bin' $false
    foreach ($sensitive in @(
        'cookies.sqlite', 'logins.json', 'key4.db', 'cert9.db',
        'places.sqlite', 'sessionstore.jsonlz4', 'storage\default\record'
    )) {
        Add-FixtureFile "Roaming\Mozilla\Firefox\Profiles\test.default\$sensitive" $true
    }
    $category = Get-CacheCategory browser
    if ($category.Default) { throw 'Browser cleanup must remain opt-in' }
    if ($category.Paths.Count -ne 7 -or
        @($category.Paths | Where-Object { $_ -notmatch '\\(Cache|Code Cache|GPUCache|cache2)$' }).Count -ne 0) {
        throw 'Unexpected browser cleanup target'
    }
    $scan = @(Invoke-CacheScan -Ids browser)
    if ($scan.Count -ne 1 -or $scan[0].Files -ne $caches.Count) { throw 'Browser scan included unexpected files' }
    $result = @(Invoke-CacheClean -Ids browser)
    if ($result.Count -ne 1 -or $result[0].Files -ne $caches.Count -or $result[0].Failed -ne 0) {
        throw 'Browser fixture cleanup failed'
    }
    foreach ($path in $caches) {
        if (Test-Path -LiteralPath $path) { throw "Cache not removed: $path" }
    }
    foreach ($path in $protected.Keys) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Account data removed: $path" }
        if ((Get-FileHash -LiteralPath $path).Hash -ne $protected[$path]) { throw "Account data changed: $path" }
    }
    Write-Host "PASS removed $($caches.Count) cache files; preserved $($protected.Count) account/site files byte-for-byte"
    Write-Host 'PASS browser cleanup is opt-in and restricted to seven cache patterns'
} finally {
    $env:LOCALAPPDATA = $originalLocal
    $env:APPDATA = $originalRoaming
    $resolved = [IO.Path]::GetFullPath($fixture)
    $allowed = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\browser-'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid fixture cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

# GachaCount: find the temporary wish-history link from the local Genshin install.
#
# How to use:
#   1. In Genshin Impact (PC) open the wish history at least once (Wish -> Records),
#      then CLOSE the game (and the launcher).
#   2. Run:  powershell -ExecutionPolicy Bypass -File .\gachacount-link.ps1
#   3. The script prints a link and copies it to the clipboard.
#      Paste it into the GachaCount app (login screen -> "Full history").
#
# The link is temporary (a couple of hours) - use it right away.
# The script only reads local game files. It sends no passwords or cookies anywhere;
# the single test request goes to the official Genshin server (public-operation-hk4e-sg.hoyoverse.com).

Add-Type -AssemblyName System.Web
$ProgressPreference = 'SilentlyContinue'

$apiHost = 'public-operation-hk4e-sg.hoyoverse.com'
$logLocation = '%userprofile%\AppData\LocalLow\miHoYo\Genshin Impact\output_log.txt'
$chinaLocation = '%userprofile%\AppData\LocalLow\miHoYo\' + [char]0x539F + [char]0x795E + '\output_log.txt'

$path = [System.Environment]::ExpandEnvironmentVariables($logLocation)
if (-Not [System.IO.File]::Exists($path)) {
    $alt = [System.Environment]::ExpandEnvironmentVariables($chinaLocation)
    if ([System.IO.File]::Exists($alt)) { $path = $alt; $apiHost = 'public-operation-hk4e.mihoyo.com' }
}
if (-Not [System.IO.File]::Exists($path)) {
    Write-Host "ERROR: log file not found: $logLocation" -ForegroundColor Red
    Write-Host "Did you launch Genshin Impact on this PC at least once?"
    return
}

$logs = Get-Content -Path $path
$m = $logs -match "(?m).:/.+(GenshinImpact_Data|YuanShen_Data)"
if ($m.Count -eq 0) {
    Write-Host "ERROR: game folder not found in the log." -ForegroundColor Red
    Write-Host "Launch the game, open Wish -> Records, close the game, run again."
    return
}
$m[0] -match "(.:/.+(GenshinImpact_Data|YuanShen_Data))" | Out-Null
$gamedir = $matches[1]
$webcachePath = "$gamedir\webCaches"

function Read-CacheFile($p) {
    try {
        $stream = [System.IO.FileStream]::new($p, 'Open', 'Read', 'ReadWrite')
        try { return [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8).ReadToEnd() } finally { $stream.Dispose() }
    } catch {}
    $tmp = Join-Path $env:TEMP ('gachacount_cache_' + [guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $p -Destination $tmp -Force -ErrorAction Stop
        return [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
    } catch { return $null } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

$seen = @{}
$candidates = New-Object System.Collections.ArrayList

# 1) webview cache of the history page (authkey + timestamp inside)
if (Test-Path $webcachePath) {
    $cacheFiles = @(Get-ChildItem -Path $webcachePath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $file = Join-Path $_.FullName 'Cache/Cache_Data/data_2'
        if (Test-Path $file) { Get-Item $file }
    } | Sort-Object LastWriteTime -Descending)
    foreach ($cf in $cacheFiles) {
        $content = Read-CacheFile $cf.FullName
        if ($null -eq $content) { continue }
        foreach ($entry in (($content -split '1/0/') -match 'webview_gacha')) {
            $match = [regex]::Match($entry, 'https://[^\x00-\x20\x7f-\uffff"''<>]+')
            if (-not $match.Success) { continue }
            try { $uri = [uri]$match.Value } catch { continue }
            if ($uri.Host -notmatch '(^|\.)(hoyoverse|mihoyo)\.com$') { continue }
            if ($uri.AbsolutePath -notmatch '(/gacha_info/api/getGachaLog$|/genshin/event/[^?]*gacha)') { continue }
            $params = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
            $ak = $params['authkey']
            if (-not $ak -or $seen.ContainsKey($ak)) { continue }
            $ts = 0; [long]::TryParse($params['timestamp'], [ref]$ts) | Out-Null
            $seen[$ak] = $true
            [void]$candidates.Add([pscustomobject]@{ AuthKey = $ak; Timestamp = $ts })
        }
    }
}

# 2) the game also logs every opened history page with authkey
$logMatches = [regex]::Matches(($logs -join "`n"), 'url: (https://\S+authkey=\S+)')
for ($n = $logMatches.Count - 1; $n -ge 0; $n -= 1) {
    try { $uri = [uri]$logMatches[$n].Groups[1].Value } catch { continue }
    if ($uri.Host -notmatch '(^|\.)(hoyoverse|mihoyo)\.com$') { continue }
    if ($uri.AbsolutePath -notmatch '/genshin/event/[^?]*gacha') { continue }
    $params = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    $ak = $params['authkey']
    if (-not $ak -or $seen.ContainsKey($ak)) { continue }
    $ts = 0; [long]::TryParse($params['timestamp'], [ref]$ts) | Out-Null
    if ($ts -eq 0) { $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    $seen[$ak] = $true
    [void]$candidates.Add([pscustomobject]@{ AuthKey = $ak; Timestamp = $ts })
}

if ($candidates.Count -eq 0) {
    Write-Host "ERROR: no wish-history link found in the game cache." -ForegroundColor Red
    Write-Host "In the game open Wish -> Records (switch between banners once),"
    Write-Host "then close the game (and launcher) and run this script again."
    return
}

$candidates = @($candidates | Sort-Object -Property Timestamp -Descending)

function Test-Link($ak) {
    foreach ($t in '301', '302', '200', '100') {
        try {
            $url = "https://$apiHost/gacha_info/api/getGachaLog?authkey=" + [System.Web.HttpUtility]::UrlEncode($ak) + "&lang=en&gacha_type=$t&size=5"
            $r = Invoke-WebRequest -Uri $url -ContentType "application/json" -UseBasicParsing -TimeoutSec 15 | ConvertFrom-Json
            if ($r.retcode -eq 0 -and @($r.data.list).Count -gt 0) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 300
    }
    return $false
}

$found = $null
for ($i = 0; $i -lt $candidates.Count; $i++) {
    Write-Host ("Checking link {0}/{1}..." -f ($i + 1), $candidates.Count)
    if (Test-Link $candidates[$i].AuthKey) { $found = $candidates[$i]; break }
    Start-Sleep -Milliseconds 500
}

if (-not $found) {
    Write-Host "ERROR: found candidate links, but none worked (expired?)." -ForegroundColor Red
    Write-Host "Open Wish -> Records in the game again, close the game,"
    Write-Host "run this script again and use the link immediately."
    return
}

$finalUrl = "https://$apiHost/gacha_info/api/getGachaLog?authkey=" + [System.Web.HttpUtility]::UrlEncode($found.AuthKey)
Write-Host ""
Write-Host "Found a working link. It is temporary - paste it into the app NOW:" -ForegroundColor Green
Write-Host $finalUrl
Set-Clipboard -Value $finalUrl
Write-Host "Link copied to the clipboard." -ForegroundColor Green

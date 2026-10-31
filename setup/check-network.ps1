# ARCA workshop: network check
#
# Checks that this network can run the workshop: Claude, the downloads the
# laptop setup needs, the tunnels that publish each team's site, and the
# central site. It installs nothing and needs no passwords or keys. It takes
# about two minutes, and saves a report beside the script.
#
# Everything it writes (the report, a downloaded cloudflared.exe if the laptop
# doesn't have one, and tunnel logs) goes in the folder holding this script,
# so deleting that folder removes all trace. Run from a pasted command
# instead of a file, it uses %TEMP%\arca-netcheck.
#
# Run it from PowerShell (admin rights not needed):
#   powershell -ExecutionPolicy Bypass -File .\check-network.ps1
#
# Written for Windows PowerShell 5.1, which every Windows 11 laptop has.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # the progress bar makes downloads many times slower
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$EventDay = [datetime]'2026-11-09'  # from here on, the central site must be up
$Results = New-Object System.Collections.Generic.List[object]
$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:TEMP 'arca-netcheck' }
$WorkDir = Join-Path $BaseDir 'netcheck-files'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Add-Result($Area, $Check, $Status, $Detail, $Fix) {
    $Results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix })
    $colour = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    $mark = @{ PASS = '  OK  '; WARN = ' WARN '; FAIL = ' FAIL ' }[$Status]
    Write-Host "[$mark] " -ForegroundColor $colour -NoNewline
    Write-Host $Check -NoNewline
    if ($Detail) { Write-Host " - $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
    if ($Status -ne 'PASS' -and $Fix) { Write-Host "         $Fix" -ForegroundColor $colour }
}

function Get-Reason($Message) {
    if ($Message -match 'could not be resolved|No such host|name or service') { return "the address couldn't be looked up" }
    if ($Message -match 'timed out|timeout') { return 'no answer (timed out)' }
    if ($Message -match 'trust relationship|certificate|SSL/TLS') { return 'the secure connection was interfered with' }
    if ($Message -match 'refused') { return 'the connection was refused' }
    return $Message
}

# An HTTP request that reports the status code instead of throwing on 4xx/5xx.
function Get-Http($Url, $TimeoutSec = 15, [switch]$ReadBody) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = 'arca-workshop-network-check'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $resp = $ex.Response }
        else { return [pscustomobject]@{ Ok = $false; Code = 0; Ms = $sw.ElapsedMilliseconds; Error = (Get-Reason $_.Exception.Message); Date = $null; Body = $null } }
    }
    $body = $null
    if ($ReadBody) {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd(); $reader.Close()
    }
    $result = [pscustomobject]@{ Ok = $true; Code = [int]$resp.StatusCode; Ms = $sw.ElapsedMilliseconds; Error = $null; Date = $resp.Headers['Date']; Body = $body }
    $resp.Close()
    return $result
}

function Test-Tcp($HostName, $Port, $TimeoutMs = 6000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $attempt = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $attempt.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($attempt)
        return $true
    } catch { return $false } finally { $client.Close() }
}

# Opens a secure connection with normal certificate checks. A network that
# inspects secure traffic presents its own certificate, which fails here.
function Test-Tls($HostName) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $attempt = $client.BeginConnect($HostName, 443, $null, $null)
        if (-not $attempt.AsyncWaitHandle.WaitOne(8000)) { return @{ Ok = $false; Detail = 'no answer (timed out)' } }
        $client.EndConnect($attempt)
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false)
        $ssl.AuthenticateAsClient($HostName)
        $issuer = $ssl.RemoteCertificate.Issuer
        $ssl.Close()
        return @{ Ok = $true; Detail = "certificate from $(($issuer -split ',')[0] -replace '^CN=','')" }
    } catch { return @{ Ok = $false; Detail = (Get-Reason $_.Exception.Message) } } finally { $client.Close() }
}

# Reads a log file that another process is still writing.
function Read-Shared($Path) {
    if (-not (Test-Path $Path)) { return '' }
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { return (New-Object System.IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Close() }
}

function Get-Cloudflared {
    $installed = Get-Command cloudflared -ErrorAction SilentlyContinue
    if ($installed) { return $installed.Source }
    $exe = Join-Path $WorkDir 'cloudflared.exe'
    if (-not (Test-Path $exe)) {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -OutFile $exe `
            -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'
    }
    return $exe
}

# Opens a throwaway tunnel to cloudflared's built-in test page, then fetches
# the page from the internet. This is the same path a team site takes.
function Test-QuickTunnel($Exe, $Protocol) {
    $log = Join-Path $WorkDir "tunnel-$Protocol.log"
    $config = Join-Path $WorkDir 'empty-config.yml'
    Set-Content -Path $config -Value ''  # never pick up a real tunnel's settings
    Remove-Item $log, "$log.out" -ErrorAction SilentlyContinue
    $arguments = @('--config', "`"$config`"", 'tunnel', '--no-autoupdate', '--hello-world', '--protocol', $Protocol)
    $process = Start-Process -FilePath $Exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardError $log -RedirectStandardOutput "$log.out"
    try {
        $url = $null
        $deadline = (Get-Date).AddSeconds(40)
        while (-not $url -and (Get-Date) -lt $deadline -and -not $process.HasExited) {
            Start-Sleep -Milliseconds 500
            $m = [regex]::Match((Read-Shared $log), 'https://[a-z0-9-]+\.trycloudflare\.com')
            if ($m.Success) { $url = $m.Value }
        }
        if (-not $url) { return @{ Ok = $false; Detail = "couldn't open a test tunnel" } }
        $deadline = (Get-Date).AddSeconds(40)
        while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
            $text = Read-Shared $log
            $used = [regex]::Match($text, 'Registered tunnel connection.*?protocol=(\w+)')
            if ($used.Success) {
                if ($used.Groups[1].Value -ne $Protocol) {
                    return @{ Ok = $false; Detail = "fell back to $($used.Groups[1].Value)" }
                }
                $page = Get-Http $url
                if ($page.Code -eq 200) { return @{ Ok = $true; Detail = 'a test page came back through the tunnel' } }
            }
            Start-Sleep -Seconds 2
        }
        $summary = [regex]::Match((Read-Shared $log), 'SUMMARY:\s*([^|]+)')
        if ($summary.Success) { return @{ Ok = $false; Detail = $summary.Groups[1].Value.Trim() } }
        return @{ Ok = $false; Detail = 'the tunnel opened, but nothing came back through it' }
    } finally {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Test-WebSocket($Url) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource 10000
    try {
        $ws.ConnectAsync([Uri]$Url, $cts.Token).GetAwaiter().GetResult()
        $buffer = [System.ArraySegment[byte]]::new((New-Object byte[] 65536))
        $reply = $ws.ReceiveAsync($buffer, $cts.Token).GetAwaiter().GetResult()
        $ws.CloseAsync('NormalClosure', 'done', [Threading.CancellationToken]::None).Wait(3000) | Out-Null
        return @{ Ok = ($reply.Count -gt 0); Detail = 'live connection opened and answered' }
    } catch { return @{ Ok = $false; Detail = (Get-Reason $_.Exception.Message) } } finally { $ws.Dispose() }
}

function Measure-Speed([switch]$Upload) {
    $client = New-Object System.Net.WebClient
    $bytes = 20000000
    if ($Upload) { $bytes = 5000000 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($Upload) { [void]$client.UploadData('https://speed.cloudflare.com/__up', 'POST', (New-Object byte[] $bytes)) }
    else { [void]$client.DownloadData("https://speed.cloudflare.com/__down?bytes=$bytes") }
    return [math]::Round($bytes * 8 / $sw.Elapsed.TotalSeconds / 1000000, 1)
}

# ---------------------------------------------------------------------------

$started = Get-Date
$wifi = (netsh wlan show interfaces 2>$null) -join "`n"
$ssid = ([regex]::Match($wifi, '(?m)^\s*SSID\s*:\s*(.+)$')).Groups[1].Value.Trim()
$signal = ([regex]::Match($wifi, '(?m)^\s*Signal\s*:\s*(.+)$')).Groups[1].Value.Trim()
if (-not $ssid) { $ssid = 'not on wifi (or unknown)' }

Write-Host ''
Write-Host 'ARCA workshop: network check' -ForegroundColor Cyan
Write-Host "Laptop $env:COMPUTERNAME on $ssid $(if ($signal) { "(signal $signal)" })"
Write-Host ''

# 1. Signed in to the wifi
$portal = Get-Http 'http://www.msftconnecttest.com/connecttest.txt' -ReadBody
if ($portal.Ok -and $portal.Body -eq 'Microsoft Connect Test') {
    Add-Result 'Wifi' 'Connected to the internet' 'PASS'
} else {
    Add-Result 'Wifi' 'Connected to the internet' 'FAIL' $(if ($portal.Error) { $portal.Error } else { 'a sign-in page answered instead' }) `
        'Open a browser and complete the hotel wifi sign-in page, then run this again.'
}

$trace = Get-Http 'https://www.cloudflare.com/cdn-cgi/trace' -ReadBody
$where = ''
if ($trace.Ok -and $trace.Body) {
    $colo = [regex]::Match($trace.Body, 'colo=(\w+)').Groups[1].Value
    $ip = [regex]::Match($trace.Body, 'ip=([^\s]+)').Groups[1].Value
    $where = "public address $ip, Cloudflare $colo"
}

$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$target = [Uri]'https://api.anthropic.com'
if ($proxy.GetProxy($target) -ne $target) {
    Add-Result 'Wifi' 'No proxy in the way' 'WARN' "traffic goes through $($proxy.GetProxy($target))" `
        'Claude Code may need HTTPS_PROXY set. Tell Warren.'
} else {
    Add-Result 'Wifi' 'No proxy in the way' 'PASS' $where
}

# 2. Claude
$tls = Test-Tls 'api.anthropic.com'
if ($tls.Ok) { Add-Result 'Claude' 'Secure connection to Claude is genuine' 'PASS' $tls.Detail }
else { Add-Result 'Claude' 'Secure connection to Claude is genuine' 'FAIL' $tls.Detail 'This network inspects secure traffic. Use the backup hotspot.' }

$api = Get-Http 'https://api.anthropic.com/v1/models'
if ($api.Ok) {
    Add-Result 'Claude' "Claude's servers answer" 'PASS' "code $($api.Code), as expected without a key"
} else {
    Add-Result 'Claude' "Claude's servers answer" 'FAIL' $api.Error 'Claude is blocked on this network. Use the backup hotspot.'
}

$times = @()
for ($i = 0; $i -lt 5; $i++) { $r = Get-Http 'https://api.anthropic.com/v1/models'; if ($r.Ok) { $times += $r.Ms } }
if ($times.Count -gt 0) {
    $median = ($times | Sort-Object)[[int][math]::Floor($times.Count / 2)]
    if ($median -le 400) { Add-Result 'Claude' 'Response time to Claude' 'PASS' "$median ms" }
    else { Add-Result 'Claude' 'Response time to Claude' 'WARN' "$median ms" 'Slow but usable. Claude Code will feel sluggish.' }
}

if ($api.Date) {
    $skew = [math]::Abs(((Get-Date).ToUniversalTime() - [datetime]::Parse($api.Date).ToUniversalTime()).TotalSeconds)
    if ($skew -le 120) { Add-Result 'Claude' "Laptop's clock is right" 'PASS' "within $([int]$skew) s" }
    else { Add-Result 'Claude' "Laptop's clock is right" 'WARN' "out by $([int]$skew) s" 'Set the clock to update automatically (Settings, Time and language).' }
}

foreach ($site in @(
        @{ Name = 'Claude Code installer'; Url = 'https://claude.ai/install.ps1'; Need200 = $true },
        @{ Name = 'Claude Code downloads'; Url = 'https://downloads.claude.ai/' },
        @{ Name = 'Claude Console'; Url = 'https://platform.claude.com/' })) {
    $r = Get-Http $site.Url
    if (-not $r.Ok) { Add-Result 'Claude' $site.Name 'FAIL' $r.Error 'Blocked on this network. Use the backup hotspot.' }
    elseif ($site.Need200 -and $r.Code -ne 200) { Add-Result 'Claude' $site.Name 'WARN' "code $($r.Code)" 'The installer may be blocked. Try opening the address in a browser.' }
    else { Add-Result 'Claude' $site.Name 'PASS' "code $($r.Code)" }
}

# 3. Downloads the laptop setup needs
foreach ($site in @(
        @{ Name = 'GitHub (starter repo, Git, cloudflared)'; Url = 'https://github.com/' },
        @{ Name = 'GitHub raw files (setup script)'; Url = 'https://raw.githubusercontent.com/' },
        @{ Name = 'GitHub release downloads'; Url = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'; Need200 = $true },
        @{ Name = 'Node.js downloads'; Url = 'https://nodejs.org/dist/index.json'; Need200 = $true },
        @{ Name = 'npm packages'; Url = 'https://registry.npmjs.org/'; Need200 = $true },
        @{ Name = 'winget (Windows installer)'; Url = 'https://cdn.winget.microsoft.com/cache/source.msix' },
        @{ Name = 'PowerShell Gallery (only if winget is missing)'; Url = 'https://www.powershellgallery.com/'; Optional = $true })) {
    $r = Get-Http $site.Url 30
    if (-not $r.Ok -and $site.Optional) { Add-Result 'Setup downloads' $site.Name 'WARN' $r.Error 'Only matters on a laptop without winget.' }
    elseif (-not $r.Ok) { Add-Result 'Setup downloads' $site.Name 'FAIL' $r.Error 'Run the laptop setup on the backup hotspot.' }
    elseif ($site.Need200 -and $r.Code -ne 200) { Add-Result 'Setup downloads' $site.Name 'WARN' "code $($r.Code)" 'This download may fail during setup.' }
    else { Add-Result 'Setup downloads' $site.Name 'PASS' "code $($r.Code)" }
}

# 4. Team sites: the tunnel
foreach ($edge in 'region1.v2.argotunnel.com', 'region2.v2.argotunnel.com') {
    if (Test-Tcp $edge 7844) { Add-Result 'Team sites' "Tunnel port 7844 open ($edge)" 'PASS' }
    else { Add-Result 'Team sites' "Tunnel port 7844 open ($edge)" 'FAIL' 'blocked' 'Ask venue IT to allow outbound port 7844 (TCP and UDP), or use the backup hotspot.' }
}

try {
    Write-Host '         Opening test tunnels (about a minute)...' -ForegroundColor DarkGray
    $cloudflared = Get-Cloudflared
    $quic = Test-QuickTunnel $cloudflared 'quic'
    $http2 = Test-QuickTunnel $cloudflared 'http2'
    if ($quic.Ok) { Add-Result 'Team sites' 'Test tunnel over QUIC (the fast way)' 'PASS' $quic.Detail }
    elseif ($http2.Ok) { Add-Result 'Team sites' 'Test tunnel over QUIC (the fast way)' 'WARN' $quic.Detail 'Fine: the tunnels will use HTTP2 instead.' }
    else { Add-Result 'Team sites' 'Test tunnel over QUIC (the fast way)' 'FAIL' $quic.Detail }
    if ($http2.Ok) { Add-Result 'Team sites' 'Test tunnel over HTTP2 (the fallback)' 'PASS' $http2.Detail }
    else { Add-Result 'Team sites' 'Test tunnel over HTTP2 (the fallback)' 'FAIL' $http2.Detail 'Team sites cannot be published from this network. Use the backup hotspot.' }
} catch {
    Add-Result 'Team sites' 'Test tunnels' 'FAIL' (Get-Reason $_.Exception.Message) "Couldn't run the tunnel test. Tell Warren."
}

# 5. The central site and the quiz
$quiz = Get-Http 'https://quiz.warrenwoolhouse.com/'
if ($quiz.Code -eq 200) { Add-Result 'Central site' 'Quiz site' 'PASS' }
else { Add-Result 'Central site' 'Quiz site' 'FAIL' $(if ($quiz.Error) { $quiz.Error } else { "code $($quiz.Code)" }) 'The quiz will not load on this network.' }

$live = Test-WebSocket 'wss://quiz.warrenwoolhouse.com/demo/ws?role=board'
if ($live.Ok) { Add-Result 'Central site' 'Live updates (WebSocket)' 'PASS' $live.Detail }
else { Add-Result 'Central site' 'Live updates (WebSocket)' 'FAIL' $live.Detail 'Live screens will not update on this network. Use the backup hotspot.' }

$severity = 'WARN'
if ((Get-Date) -ge $EventDay) { $severity = 'FAIL' }
$workshop = Get-Http 'https://workshop.warrenwoolhouse.com/'
if ($workshop.Ok -and $workshop.Code -lt 500) { Add-Result 'Central site' 'Workshop site' 'PASS' "code $($workshop.Code)" }
else { Add-Result 'Central site' 'Workshop site' $severity $(if ($workshop.Error) { $workshop.Error } else { "code $($workshop.Code)" }) 'Not reachable. Before 9 November this just means it is not built yet.' }

# 6. Speed (this laptop's share of the network)
try {
    $down = Measure-Speed
    if ($down -ge 20) { Add-Result 'Speed' 'Download speed' 'PASS' "$down Mbit/s" }
    elseif ($down -ge 5) { Add-Result 'Speed' 'Download speed' 'WARN' "$down Mbit/s" 'Fine for the workshop; laptop setup downloads will be slow. Set up a few laptops at a time.' }
    else { Add-Result 'Speed' 'Download speed' 'FAIL' "$down Mbit/s" 'Too slow for setup. Use the backup hotspot for setup.' }
    $up = Measure-Speed -Upload
    if ($up -ge 5) { Add-Result 'Speed' 'Upload speed' 'PASS' "$up Mbit/s" }
    elseif ($up -ge 1) { Add-Result 'Speed' 'Upload speed' 'WARN' "$up Mbit/s" 'Team sites will be slow to load on phones.' }
    else { Add-Result 'Speed' 'Upload speed' 'FAIL' "$up Mbit/s" 'Too slow to publish team sites. Use the backup hotspot.' }
} catch {
    Add-Result 'Speed' 'Speed test' 'WARN' (Get-Reason $_.Exception.Message) "Couldn't measure speed."
}

# ---------------------------------------------------------------------------

$fails = @($Results | Where-Object Status -eq 'FAIL')
$warns = @($Results | Where-Object Status -eq 'WARN')
Write-Host ''
if ($fails.Count -eq 0 -and $warns.Count -eq 0) {
    $verdict = 'READY: this network can run the workshop.'; $colour = 'Green'
} elseif ($fails.Count -eq 0) {
    $verdict = "READY, WITH $($warns.Count) WARNING(S): read the yellow lines."; $colour = 'Yellow'
} else {
    $areas = ($fails | Select-Object -ExpandProperty Area -Unique) -join ', '
    $verdict = "NOT READY: $($fails.Count) problem(s) in $areas. Read the red lines."; $colour = 'Red'
}
Write-Host $verdict -ForegroundColor $colour

$report = Join-Path $BaseDir ("network-check-{0:yyyyMMdd-HHmm}.txt" -f $started)
@(
    'ARCA workshop: network check'
    "When:    $started"
    "Laptop:  $env:COMPUTERNAME"
    "Wifi:    $ssid $signal"
    "Network: $where"
    "Verdict: $verdict"
    ''
    ($Results | Format-Table Status, Area, Check, Detail, Fix -AutoSize -Wrap | Out-String -Width 220)
) | Set-Content -Path $report -Encoding UTF8
Write-Host "Report saved to $report"
Write-Host ''

if ($fails.Count -gt 0) { exit 1 } else { exit 0 }

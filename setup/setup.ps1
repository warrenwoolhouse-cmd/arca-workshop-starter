# ARCA workshop: laptop setup
#
# Sets up one table's laptop from nothing: the programs it needs, the table's
# folder, its keys, its site and tunnel, and Claude Code. Run it from an
# administrator PowerShell window with this one command:
#
#   irm https://raw.githubusercontent.com/warrenwoolhouse-cmd/arca-workshop-starter/main/setup/setup.ps1 | iex
#
# It asks for the table number and the admin password. It's safe to run again:
# a second run for the same table repairs anything missing and leaves the
# table's work alone. A different table number moves the old folder aside and
# sets the laptop up as the new table. setup/reset.ps1 undoes all of it.
#
# It never prints, logs or saves the password, and it prints and logs none of
# the keys it fetches. Its log is C:\Workshop\setup\setup-log.txt.
#
# Written for Windows PowerShell 5.1, which every Windows 11 laptop has.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # the progress bar makes downloads many times slower
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo = 'https://github.com/warrenwoolhouse-cmd/arca-workshop-starter'
$RawBase = 'https://raw.githubusercontent.com/warrenwoolhouse-cmd/arca-workshop-starter/main'
$CentralUrl = 'https://workshop.warrenwoolhouse.com'
$UserAgent = 'arca-workshop-setup/1.0'  # Cloudflare refuses some default user agents (error 1010)
$Root = 'C:\Workshop'
$TeamDir = 'C:\Workshop\team'
$SetupDir = 'C:\Workshop\setup'
$LogFile = Join-Path $SetupDir 'setup-log.txt'
$StateFile = Join-Path $SetupDir 'state.json'
$TaskName = 'ARCA workshop site'
$ShortcutName = 'Start workshop.lnk'
$ClaudeMinVersion = [version]'2.1.233'  # auto mode on native Windows
$EnvNames = @('ANTHROPIC_API_KEY', 'WORKSHOP_TEAM', 'WORKSHOP_TEAM_NAME', 'WORKSHOP_TEAM_TOKEN', 'WORKSHOP_SITE_URL', 'WORKSHOP_CENTRAL_URL')
# For testing only: a folder holding starter.zip and check-network.ps1 to use
# instead of downloading them.
$Kit = $env:ARCA_SETUP_KIT

# ---------------------------------------------------------------------------
# Output and logging

function Write-Log([string]$Text) {
    try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Text) -Encoding UTF8 } catch {}
}
function Say([string]$Text) { Write-Host $Text; Write-Log $Text }
function Say-Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan; Write-Log "== $Text" }
function Say-Ok([string]$Text) { Write-Host '[  OK  ] ' -ForegroundColor Green -NoNewline; Write-Host $Text; Write-Log "OK   $Text" }
function Say-Warn([string]$Text) { Write-Host '[ WARN ] ' -ForegroundColor Yellow -NoNewline; Write-Host $Text; Write-Log "WARN $Text" }
function Say-Fail([string]$Text) { Write-Host '[ FAIL ] ' -ForegroundColor Red -NoNewline; Write-Host $Text; Write-Log "FAIL $Text" }

# Stops setup with a plain-English reason. Invoke-Setup catches it.
function Stop-Setup([string]$Reason) { throw (New-Object System.Exception ("SETUP-STOP:" + $Reason)) }

# Runs a program and returns its exit code and output. With -Secret, neither
# the arguments nor the output reach the log.
function Invoke-Program([string]$Exe, [string[]]$Arguments = @(), [switch]$Secret, [string]$WorkDir) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'  # Windows PowerShell treats a program's stderr as an error otherwise
    if ($WorkDir) { Push-Location $WorkDir }
    try {
        $output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        if ($WorkDir) { Pop-Location }
        $ErrorActionPreference = $old
    }
    $text = ($output -join "`n").Trim()
    if ($Secret) { Write-Log "ran $(Split-Path $Exe -Leaf) (details not logged): exit $code" }
    else {
        Write-Log "ran $(Split-Path $Exe -Leaf) $($Arguments -join ' '): exit $code"
        if ($text) { Write-Log $text }
    }
    return [pscustomobject]@{ Code = $code; Output = $text }
}

# An HTTP request that reports the status code instead of throwing on 4xx/5xx.
function Invoke-Http([string]$Method, [string]$Url, [string]$Body, [hashtable]$Headers = @{}, [int]$TimeoutSec = 20) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = $UserAgent
    $req.AllowAutoRedirect = $false
    foreach ($k in $Headers.Keys) { $req.Headers[$k] = $Headers[$k] }
    $resp = $null
    try {
        if ($Body) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $req.ContentType = 'application/json'
            $req.ContentLength = $bytes.Length
            $stream = $req.GetRequestStream(); $stream.Write($bytes, 0, $bytes.Length); $stream.Close()
        }
        $resp = $req.GetResponse()
    } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $resp = $ex.Response }
        else { return [pscustomobject]@{ Code = 0; Body = $null } }
    }
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $text = $reader.ReadToEnd(); $reader.Close()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return [pscustomobject]@{ Code = $code; Body = $text }
}

function Get-ErrorText([string]$Body) {
    try { $e = ($Body | ConvertFrom-Json).error; if ($e) { return [string]$e } } catch {}
    return ''
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user, (Join-Path $env:USERPROFILE '.local\bin')) | Where-Object { $_ }) -join ';'
}

function Write-TextFile([string]$Path, [string]$Text) {
    # UTF-8 without a byte-order mark: Claude Code reads these files as JSON.
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# Sets a property on an object read from JSON, adding it if it isn't there.
function Set-Prop($Object, [string]$Name, $Value) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}
function Get-Prop($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return New-Object psobject }
    $text = [IO.File]::ReadAllText($Path)
    if (-not $text.Trim()) { return New-Object psobject }
    return ($text | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# What setup remembers between runs (no secrets): the table, what it
# installed, and the power settings it found.

function Read-State {
    try { $s = Read-JsonFile $StateFile } catch { $s = New-Object psobject }
    if (-not (Get-Prop $s 'installed')) { Set-Prop $s 'installed' (New-Object psobject) }
    return $s
}
function Save-State($State) { Write-TextFile $StateFile ($State | ConvertTo-Json -Depth 10) }
function Set-Installed($State, [string]$Name) { Set-Prop $State.installed $Name $true; Save-State $State }

# ---------------------------------------------------------------------------
# Checks before anything changes

function Assert-Ready {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Setup 'This window isn''t running as administrator. Right-click Start, choose "Terminal (Admin)", and paste the setup command again.'
    }
    # Claude Code, its settings and the keys belong to the person signed in to
    # Windows. Elevating as a different account would set up the wrong one.
    $me = $env:USERNAME
    $owners = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue).User } |
        Where-Object { $_ } | Select-Object -Unique)
    if ($owners.Count -gt 0 -and $owners -notcontains $me) {
        Stop-Setup "This window is running as $me, but $($owners -join ', ') is signed in to Windows. Sign in to Windows as the account the table will use (it must be an administrator), then run setup there."
    }
}

function Invoke-NetworkCheck {
    Say-Step 'Checking the network (about two minutes)'
    $script = Join-Path $SetupDir 'check-network.ps1'
    if ($Kit) { Copy-Item (Join-Path $Kit 'check-network.ps1') $script -Force }
    else {
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "$RawBase/setup/check-network.ps1" -UserAgent $UserAgent -OutFile $script }
        catch { Stop-Setup 'Couldn''t download the network check. Check this laptop is on the wifi (and signed in to it), then run setup again.' }
    }
    # Run it in its own window process: it ends with exit, which would close this one.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script
    if ($LASTEXITCODE -ne 0) {
        Stop-Setup 'The network check found a problem: read the red lines above. Fix it (or switch to the backup hotspot), then run setup again.'
    }
    Write-Log 'network check passed'
}

# ---------------------------------------------------------------------------
# Programs

function Find-GitBash {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) { $candidates += (Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe') }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}
function Get-NodeMajor {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { return 0 }
    $v = (Invoke-Program $node.Source @('--version')).Output
    if ($v -match '^v(\d+)\.') { return [int]$Matches[1] }
    return 0
}
function Find-Cloudflared {
    $c = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @((Join-Path ${env:ProgramFiles(x86)} 'cloudflared\cloudflared.exe'), (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe'))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}
function Find-Claude {
    $p = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $p) { return $p }
    $c = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}
function Get-ClaudeVersion([string]$Exe) {
    $out = (Invoke-Program $Exe @('--version')).Output
    if ($out -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}

function Assert-Winget($State) {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { Say-Ok 'winget is ready'; return }
    # A laptop whose user has only just signed in for the first time may not
    # have registered it yet.
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { Write-Log "winget register: $($_.Exception.Message)" }
    Update-SessionPath
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { Say-Ok 'winget is ready'; return }
    Say 'Installing winget, the Windows installer (a few minutes)...'
    try {
        # Microsoft's documented bootstrap for machines without winget.
        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers | Out-Null
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager -AllUsers | Out-Null
    } catch { Write-Log "winget bootstrap: $($_.Exception.Message)" }
    Update-SessionPath
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        $wa = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
        if (Test-Path (Join-Path $wa 'winget.exe')) { $env:Path = "$env:Path;$wa" }
    }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Stop-Setup 'Couldn''t install winget, the Windows installer. Open the Microsoft Store, update "App Installer", then run setup again.'
    }
    Set-Installed $State 'winget'
    Say-Ok 'winget installed'
}

function Install-Package($State, [string]$Key, [string]$Id, [string]$Name, [scriptblock]$IsPresent) {
    if (& $IsPresent) { Say-Ok "$Name is installed"; return }
    Say "Installing $Name..."
    $r = Invoke-Program 'winget.exe' @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    Update-SessionPath
    if (-not (& $IsPresent)) {
        Stop-Setup "Couldn't install $Name (winget said $($r.Code)). Check the wifi, then run setup again. The details are in $LogFile."
    }
    Set-Installed $State $Key
    Say-Ok "$Name installed"
}

function Install-Programs($State) {
    Say-Step 'Installing the programs'
    Assert-Winget $State
    Install-Package $State 'git' 'Git.Git' 'Git' { [bool](Find-GitBash) }
    Install-Package $State 'node' 'OpenJS.NodeJS.LTS' 'Node.js' { (Get-NodeMajor) -ge 20 }
    Install-Package $State 'cloudflared' 'Cloudflare.cloudflared' 'cloudflared (the tunnel)' { [bool](Find-Cloudflared) }

    $claude = Find-Claude
    $version = $null
    if ($claude) { $version = Get-ClaudeVersion $claude }
    if ($claude -and $version -and $version -ge $ClaudeMinVersion) {
        Say-Ok "Claude Code $version is installed"
    } else {
        Say 'Installing Claude Code...'
        # Anthropic's native Windows installer, in its own process.
        $r = Invoke-Program 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://claude.ai/install.ps1 | iex')
        Update-SessionPath
        $claude = Find-Claude
        if ($claude) { $version = Get-ClaudeVersion $claude }
        if (-not $claude -or -not $version) {
            Stop-Setup "Couldn't install Claude Code (the installer said $($r.Code)). Check the wifi, then run setup again. The details are in $LogFile."
        }
        Set-Installed $State 'claude'
        Say-Ok "Claude Code $version installed"
    }
    return $claude
}

# ---------------------------------------------------------------------------
# The table's keys

function Read-TableNumber($Default) {
    while ($true) {
        $prompt = 'Table number (1 to 12)'
        if ($Default) { $prompt = "Table number (1 to 12). Press Enter to keep table $Default" }
        $answer = (Read-Host $prompt).Trim()
        if (-not $answer -and $Default) { return [int]$Default }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le 12) { return $n }
        Write-Host 'Type a number from 1 to 12.' -ForegroundColor Yellow
    }
}

function ConvertFrom-Secure([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# Asks the central site for this table's keys. Returns the parsed reply; it is
# never printed or logged.
function Get-TableKeys([int]$Team) {
    $wrong = 0
    $secure = Read-Host 'Admin password (it won''t show as you type)' -AsSecureString
    while ($true) {
        $plain = ConvertFrom-Secure $secure
        $body = @{ team = $Team; password = $plain } | ConvertTo-Json -Compress
        $plain = $null
        $r = Invoke-Http 'POST' "$CentralUrl/api/setup" $body
        $body = $null
        Write-Log "setup endpoint for table ${Team}: $($r.Code)"
        switch ($r.Code) {
            200 {
                try { $keys = $r.Body | ConvertFrom-Json } catch { $keys = $null }
                foreach ($f in 'token', 'anthropic_api_key', 'tunnel_token', 'site_url', 'team_page_url', 'name') {
                    if (-not $keys -or -not (Get-Prop $keys $f)) { Stop-Setup 'The workshop site sent back something unexpected. Tell Warren.' }
                }
                if ([int]$keys.team -ne $Team) { Stop-Setup 'The workshop site sent back a different table. Tell Warren.' }
                return $keys
            }
            401 {
                $wrong++
                if ($wrong -ge 3) { Stop-Setup 'That password was wrong three times. Check it on the admin page, then run setup again.' }
                Write-Host 'That password wasn''t right.' -ForegroundColor Yellow
                $secure = Read-Host 'Admin password' -AsSecureString
            }
            403 {
                Write-Host 'Setup is closed. Open it on the admin page (Setup: Open), then press Enter here to try again.' -ForegroundColor Yellow
                [void](Read-Host)
            }
            429 { Stop-Setup 'Too many wrong passwords from this network. Wait 10 minutes, then run setup again.' }
            { $_ -eq 404 -or $_ -eq 409 } {
                $why = Get-ErrorText $r.Body
                if (-not $why) { $why = "Table $Team isn't ready on the admin page." }
                Write-Host "$why Fix it on the admin page, then press Enter here to try again." -ForegroundColor Yellow
                [void](Read-Host)
            }
            0 { Stop-Setup "Couldn't reach the workshop site ($CentralUrl). Check this laptop is on the wifi, then run setup again." }
            default { Stop-Setup "The workshop site answered $($r.Code). Try again in a minute; if it keeps happening, tell Warren." }
        }
    }
}

# ---------------------------------------------------------------------------
# The table's folder

function Stop-Site {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine -like "*$TeamDir*" -or $_.CommandLine -like '*run-site.ps1*') -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-StarterZip {
    $zip = Join-Path $SetupDir 'starter.zip'
    if ($Kit) { Copy-Item (Join-Path $Kit 'starter.zip') $zip -Force; return $zip }
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri "$Repo/archive/refs/heads/main.zip" -UserAgent $UserAgent -OutFile $zip }
    catch { Stop-Setup 'Couldn''t download the workshop files from GitHub. Check the wifi, then run setup again.' }
    return $zip
}

function Install-TeamFolder($State, [int]$Team) {
    Say-Step "Setting up the table's folder ($TeamDir)"
    $exists = Test-Path (Join-Path $TeamDir 'package.json')
    if ($exists -and [int](Get-Prop $State 'team') -eq $Team) {
        Say-Ok "Kept the folder and everything the table has done in it"
    } else {
        if (Test-Path $TeamDir) {
            Stop-Site
            $aside = "$TeamDir-old-{0:yyyyMMdd-HHmmss}" -f (Get-Date)
            Move-Item $TeamDir $aside
            Say-Ok "Moved the previous folder aside to $aside"
        }
        $zip = Get-StarterZip
        $unpack = Join-Path $SetupDir 'unpack'
        if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $unpack -Force
        $top = @(Get-ChildItem $unpack -Directory)
        if ($top.Count -ne 1 -or -not (Test-Path (Join-Path $top[0].FullName 'package.json'))) {
            Stop-Setup 'The workshop files downloaded from GitHub look wrong. Tell Warren.'
        }
        Move-Item $top[0].FullName $TeamDir
        Remove-Item $unpack, $zip -Recurse -Force
        Set-Prop $State 'team' $Team
        Save-State $State
        Say-Ok 'Downloaded the workshop files'
    }

    if (-not (Test-Path (Join-Path $TeamDir 'node_modules\@anthropic-ai\sdk'))) {
        $npm = Join-Path (Split-Path (Get-Command node.exe).Source) 'npm.cmd'
        $r = Invoke-Program $npm @('ci', '--no-audit', '--no-fund', '--loglevel=error') -WorkDir $TeamDir
        if ($r.Code -ne 0) { Stop-Setup "Couldn't install the folder's packages (npm said $($r.Code)). Check the wifi, then run setup again." }
        Say-Ok 'Installed the packages the table''s tools use'
    }

    # A private undo history for Claude Code, with no remote. Nobody at the
    # table needs to know it's there.
    $git = (Get-Command git.exe).Source
    if (-not (Test-Path (Join-Path $TeamDir '.git'))) {
        [void](Invoke-Program $git @('init', '-q', '-b', 'main') -WorkDir $TeamDir)
    }
    foreach ($pair in @(@('user.name', "Table $Team"), @('user.email', "table$Team@example.com"), @('core.autocrlf', 'false'))) {
        $current = (Invoke-Program $git @('config', '--local', '--get', $pair[0]) -WorkDir $TeamDir).Output
        if ($current -ne $pair[1]) { [void](Invoke-Program $git @('config', '--local', $pair[0], $pair[1]) -WorkDir $TeamDir) }
    }
    $head = Invoke-Program $git @('rev-parse', '--verify', '-q', 'HEAD') -WorkDir $TeamDir
    if ($head.Code -ne 0) {
        [void](Invoke-Program $git @('add', '-A') -WorkDir $TeamDir)
        $c = Invoke-Program $git @('commit', '-q', '-m', 'Starting files') -WorkDir $TeamDir
        if ($c.Code -ne 0) { Stop-Setup "Couldn't save the starting files in the folder's history. The details are in $LogFile." }
        Say-Ok 'Saved the starting files (Claude Code''s undo history)'
    }
}

# Folders made from an administrator window belong to Administrators, and Git
# refuses to work in a folder owned by someone else. Hand everything to the
# person signed in.
function Set-FolderOwner {
    $who = "$env:USERDOMAIN\$env:USERNAME"
    [void](Invoke-Program 'icacls.exe' @($Root, '/grant', "${who}:(OI)(CI)F", '/T', '/C', '/Q'))
    [void](Invoke-Program 'icacls.exe' @($Root, '/setowner', $who, '/T', '/C', '/Q'))
}

# ---------------------------------------------------------------------------
# Settings

function Set-TableEnvironment($Keys) {
    Say-Step 'Saving the table''s settings'
    $values = [ordered]@{
        ANTHROPIC_API_KEY    = [string]$Keys.anthropic_api_key
        WORKSHOP_TEAM        = [string]$Keys.team
        WORKSHOP_TEAM_NAME   = [string]$Keys.name
        WORKSHOP_TEAM_TOKEN  = [string]$Keys.token
        WORKSHOP_SITE_URL    = ([string]$Keys.site_url).TrimEnd('/')
        WORKSHOP_CENTRAL_URL = $CentralUrl
    }
    $changed = $false
    foreach ($name in $values.Keys) {
        if ([Environment]::GetEnvironmentVariable($name, 'User') -ne $values[$name]) {
            [Environment]::SetEnvironmentVariable($name, $values[$name], 'User')
            $changed = $true
        }
        Set-Item "env:$name" $values[$name]
    }
    if ($changed) { Say-Ok 'Saved the table''s settings and keys' } else { Say-Ok 'The table''s settings and keys were already saved' }
    return $changed
}

# Claude Code for people who have never seen a terminal: Sonnet, auto mode
# (a background safety check instead of yes/no questions), Git Bash, and no
# updates during the event. Merged into any settings already there.
function Set-ClaudeSettings([string]$ApiKey) {
    $dir = Join-Path $env:USERPROFILE '.claude'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir 'settings.json'
    try { $s = Read-JsonFile $path } catch { Copy-Item $path "$path.broken" -Force; $s = New-Object psobject }
    $before = $s | ConvertTo-Json -Depth 20
    Set-Prop $s 'model' 'sonnet'
    $perm = Get-Prop $s 'permissions'
    if (-not $perm) { $perm = New-Object psobject; Set-Prop $s 'permissions' $perm }
    Set-Prop $perm 'defaultMode' 'auto'
    $envBlock = Get-Prop $s 'env'
    if (-not $envBlock) { $envBlock = New-Object psobject; Set-Prop $s 'env' $envBlock }
    Set-Prop $envBlock 'CLAUDE_CODE_GIT_BASH_PATH' (Find-GitBash)
    Set-Prop $envBlock 'DISABLE_AUTOUPDATER' '1'
    $after = $s | ConvertTo-Json -Depth 20
    if ($after -ne $before) { Write-TextFile $path $after }

    # First-launch questions. Claude Code keeps these answers in ~/.claude.json;
    # the docs don't describe setting them in advance, so the night-before
    # /hello on each laptop is the check that this worked.
    $statePath = Join-Path $env:USERPROFILE '.claude.json'
    try { $g = Read-JsonFile $statePath } catch {
        Say-Warn 'Claude Code''s own settings file couldn''t be read, so its first launch may ask a few questions. Answer them once.'
        return
    }
    $before = $g | ConvertTo-Json -Depth 50
    Set-Prop $g 'hasCompletedOnboarding' $true
    $responses = Get-Prop $g 'customApiKeyResponses'
    if (-not $responses) { $responses = New-Object psobject; Set-Prop $g 'customApiKeyResponses' $responses }
    $approved = @(Get-Prop $responses 'approved' | Where-Object { $_ })
    $tail = $ApiKey.Substring([Math]::Max(0, $ApiKey.Length - 20))
    if ($approved -notcontains $tail) { $approved += $tail }
    Set-Prop $responses 'approved' ([object[]]$approved)
    if (-not (Get-Prop $responses 'rejected')) { Set-Prop $responses 'rejected' ([object[]]@()) }
    $projects = Get-Prop $g 'projects'
    if (-not $projects) { $projects = New-Object psobject; Set-Prop $g 'projects' $projects }
    foreach ($key in @(($TeamDir -replace '\\', '/'), $TeamDir)) {
        $p = Get-Prop $projects $key
        if (-not $p) { $p = New-Object psobject; Set-Prop $projects $key $p }
        Set-Prop $p 'hasTrustDialogAccepted' $true
    }
    $after = $g | ConvertTo-Json -Depth 50
    if ($after -ne $before) { Write-TextFile $statePath $after }
    Say-Ok 'Claude Code: Sonnet, no yes/no questions for routine work, key approved'
}

# ---------------------------------------------------------------------------
# The tunnel and the site

function Install-Tunnel([string]$TunnelToken) {
    Say-Step 'Publishing the table''s site through its tunnel'
    $exe = Find-Cloudflared
    $svc = Get-Service -Name Cloudflared -ErrorAction SilentlyContinue
    $image = ''
    try { $image = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared' -ErrorAction Stop).ImagePath } catch {}
    if ($svc -and $image -and $image.Contains($TunnelToken)) {
        if ($svc.Status -ne 'Running') { Start-Service Cloudflared }
        Say-Ok 'The tunnel service is installed and running'
        return
    }
    if ($svc) {
        Stop-Service Cloudflared -Force -ErrorAction SilentlyContinue
        [void](Invoke-Program $exe @('service', 'uninstall'))
        Start-Sleep -Seconds 2
    }
    $r = Invoke-Program $exe @('service', 'install', $TunnelToken) -Secret
    if (-not (Get-Service -Name Cloudflared -ErrorAction SilentlyContinue)) {
        Stop-Setup "Couldn't install the tunnel service (cloudflared said $($r.Code)). Tell Warren."
    }
    # Restart it if it ever stops.
    [void](Invoke-Program 'sc.exe' @('failure', 'Cloudflared', 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/5000'))
    if ((Get-Service Cloudflared).Status -ne 'Running') { Start-Service Cloudflared }
    Say-Ok 'Installed the tunnel as a Windows service'
}

# The script the scheduled task runs. It reads the table's settings fresh
# each time, so it never holds a key itself, and restarts the site if it stops.
function Write-SiteRunner([string]$NodeExe) {
    $runner = @"
# Runs the table's site and restarts it if it stops. Started by the
# "$TaskName" scheduled task, which setup.ps1 creates.
`$ErrorActionPreference = 'Continue'
`$names = @('$($EnvNames -join "', '")')
`$log = '$SetupDir\site-runner.log'
while (`$true) {
    foreach (`$n in `$names) {
        `$v = [Environment]::GetEnvironmentVariable(`$n, 'User')
        if (`$v) { Set-Item "env:`$n" `$v }
    }
    if (-not `$env:WORKSHOP_TEAM) { Add-Content `$log "`$(Get-Date -Format s) The table's settings are missing; waiting." ; Start-Sleep 30; continue }
    Set-Location '$TeamDir'
    Add-Content `$log "`$(Get-Date -Format s) Starting the site."
    & '$NodeExe' '$TeamDir\server\supervisor.js' *> `$null
    Add-Content `$log "`$(Get-Date -Format s) The site stopped (`$LASTEXITCODE); starting it again."
    Start-Sleep -Seconds 3
}
"@
    $path = Join-Path $SetupDir 'run-site.ps1'
    $old = if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { '' }
    if ($old -ne $runner) { Write-TextFile $path $runner; return $true }
    return $false
}

function Test-LocalSite([int]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $r = Invoke-Http 'GET' 'http://127.0.0.1:8080/workshop.json' $null @{} 5
        if ($r.Code -eq 200) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Register-SiteTask([string]$LogonType) {
    $who = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SetupDir\run-site.ps1`"" -WorkingDirectory $TeamDir
    $triggers = @(New-ScheduledTaskTrigger -AtLogOn -User $who)
    # Without a stored password (S4U), the site also starts before anyone signs in.
    if ($LogonType -eq 'S4U') { $triggers += New-ScheduledTaskTrigger -AtStartup }
    $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType $LogonType -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
}

function Install-SiteTask([bool]$Restart) {
    $node = (Get-Command node.exe).Source
    $runnerChanged = Write-SiteRunner $node
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        try { Register-SiteTask 'S4U' } catch { Write-Log "S4U task: $($_.Exception.Message)"; Register-SiteTask 'Interactive' }
        $Restart = $true
    }
    if ($Restart -or $runnerChanged) { Stop-Site }
    if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') { Start-ScheduledTask -TaskName $TaskName }
    if (Test-LocalSite 40) { Say-Ok 'The site starts by itself and restarts if it stops'; return }
    # Some accounts can't run a task without being signed in; fall back to
    # starting the site when the person signs in.
    Write-Log 'site did not start under S4U; switching to the signed-in user'
    Stop-Site
    Register-SiteTask 'Interactive'
    Start-ScheduledTask -TaskName $TaskName
    if (Test-LocalSite 40) { Say-Ok 'The site starts when you sign in and restarts if it stops'; return }
    Stop-Setup "The site didn't start. The details are in $TeamDir\logs\server.log. Tell Warren."
}

# ---------------------------------------------------------------------------
# The laptop: power, updates, the desktop shortcut

function Get-PowerValue([string]$Sub, [string]$Setting) {
    $out = (Invoke-Program 'powercfg.exe' @('/query', 'SCHEME_CURRENT', $Sub, $Setting)).Output
    $ac = [regex]::Match($out, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    $dc = [regex]::Match($out, 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if (-not $ac.Success) { return $null }
    $r = [ordered]@{ ac = [Convert]::ToInt32($ac.Groups[1].Value, 16) }
    if ($dc.Success) { $r.dc = [Convert]::ToInt32($dc.Groups[1].Value, 16) }
    return [pscustomobject]$r
}

$PowerSettings = @(
    @('SUB_SLEEP', 'STANDBYIDLE'),   # sleep after
    @('SUB_SLEEP', 'HIBERNATEIDLE'), # hibernate after
    @('SUB_VIDEO', 'VIDEOIDLE'),     # screen off after (it locks when it comes back)
    @('SUB_BUTTONS', 'LIDACTION'))   # closing the lid

function Set-PowerAndUpdates($State) {
    Say-Step 'Keeping the laptop awake'
    if (-not (Get-Prop $State 'power_before')) {
        $before = New-Object psobject
        foreach ($p in $PowerSettings) {
            $v = Get-PowerValue $p[0] $p[1]
            if ($v) { Set-Prop $before "$($p[0])/$($p[1])" $v }
        }
        Set-Prop $State 'power_before' $before
        Save-State $State
    }
    $ok = $true
    $changed = $false
    foreach ($p in $PowerSettings) {
        $v = Get-PowerValue $p[0] $p[1]
        if (-not $v) { $ok = $false; continue }
        if ($v.ac -ne 0) { [void](Invoke-Program 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', $p[0], $p[1], '0')); $changed = $true }
        if ($null -ne $v.dc -and $v.dc -ne 0) { [void](Invoke-Program 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', $p[0], $p[1], '0')); $changed = $true }
    }
    if ($changed) { [void](Invoke-Program 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT')) }
    if ($ok) { Say-Ok 'Never sleeps, the screen stays on, and closing the lid does nothing' }
    else { Say-Warn 'Couldn''t read some power settings. Set "Sleep: Never" and "Closing the lid: Do nothing" in Control Panel, Power Options.' }

    # Pause Windows Update for a week, so it can't restart the laptop mid-workshop.
    $key = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $now = (Get-Date).ToUniversalTime()
    $current = $null
    try { $current = [datetime]::Parse((Get-ItemProperty $key -ErrorAction Stop).PauseUpdatesExpiryTime).ToUniversalTime() } catch {}
    if ($current -and $current -gt $now.AddDays(3)) {
        Say-Ok "Windows Update is paused until $($current.ToLocalTime().ToString('d MMM'))"
        return
    }
    try {
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        $start = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $end = $now.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ')
        foreach ($pair in @(@('PauseUpdatesStartTime', $start), @('PauseUpdatesExpiryTime', $end),
                @('PauseFeatureUpdatesStartTime', $start), @('PauseFeatureUpdatesEndTime', $end),
                @('PauseQualityUpdatesStartTime', $start), @('PauseQualityUpdatesEndTime', $end))) {
            Set-ItemProperty -Path $key -Name $pair[0] -Value $pair[1] -Type String
        }
        Set-Prop $State 'paused_updates' $true
        Save-State $State
        Say-Ok "Paused Windows Update until $($now.AddDays(7).ToLocalTime().ToString('d MMM'))"
    } catch { Say-Warn 'Couldn''t pause Windows Update. Pause it for a week in Settings, Windows Update.' }
}

function Install-Shortcut([string]$ClaudeExe) {
    $start = @"
# Opens the workshop: the team page and the team's site in the browser, and
# Claude Code in the table's folder. The "Start workshop" desktop shortcut
# runs this. It reads the table's settings fresh, so it holds no key itself.
foreach (`$n in @('$($EnvNames -join "', '")')) {
    `$v = [Environment]::GetEnvironmentVariable(`$n, 'User')
    if (`$v) { Set-Item "env:`$n" `$v }
}
`$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
if (`$env:WORKSHOP_TEAM_TOKEN) {
    Start-Process "`$env:WORKSHOP_CENTRAL_URL/team/`$env:WORKSHOP_TEAM_TOKEN"
    Start-Process "`$env:WORKSHOP_SITE_URL/dashboard.html?key=`$env:WORKSHOP_TEAM_TOKEN"
}
`$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if (`$wt) { Start-Process `$wt.Source -ArgumentList @('-d', '"$TeamDir"', '"$ClaudeExe"') }
else { Start-Process -FilePath '$ClaudeExe' -WorkingDirectory '$TeamDir' }
"@
    $path = Join-Path $SetupDir 'start-workshop.ps1'
    $old = if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { '' }
    if ($old -ne $start) { Write-TextFile $path $start }

    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$path`""
    $s.WorkingDirectory = $TeamDir
    $s.IconLocation = "$ClaudeExe,0"
    $s.Description = 'Open the workshop: Claude Code, the team page and the team site'
    $s.Save()
    Say-Ok 'Put a "Start workshop" shortcut on the desktop'
    return $lnk
}

# ---------------------------------------------------------------------------
# Self-test

function Invoke-SelfTest([string]$ClaudeExe, $Keys) {
    Say-Step 'Checking everything works'
    $failed = 0

    # 1. Claude Code answers, with this table's key.
    $out = Join-Path $SetupDir 'selftest-claude.txt'
    $p = Start-Process -FilePath $ClaudeExe -ArgumentList '-p "Reply with just the word: ready"' -WorkingDirectory $TeamDir `
        -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    if (-not $p.WaitForExit(180000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $answer = ''
    if (Test-Path $out) { $answer = [IO.File]::ReadAllText($out) }
    if ($answer -match 'ready') { Say-Ok 'Claude Code answers' }
    else {
        $failed++
        $err = if (Test-Path "$out.err") { [IO.File]::ReadAllText("$out.err").Trim() } else { '' }
        Write-Log "claude -p said: $answer $err"
        Say-Fail 'Claude Code didn''t answer. Check the table''s Anthropic key on the admin page, then run setup again.'
    }
    Remove-Item $out, "$out.err" -ErrorAction SilentlyContinue

    # 2. The site on the laptop.
    if (Test-LocalSite 20) { Say-Ok 'The site answers on this laptop' }
    else { $failed++; Say-Fail "The site isn't answering. The details are in $TeamDir\logs\server.log." }

    # 3. The site through the tunnel: open with the key, closed without it.
    $site = ([string]$Keys.site_url).TrimEnd('/')
    $with = $null; $without = $null
    $end = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $end) {
        $with = Invoke-Http 'GET' "$site/workshop.json" $null @{ 'X-Workshop-Key' = [string]$Keys.token; 'Cache-Control' = 'no-store' } 10
        if ($with.Code -eq 200) { break }
        Start-Sleep -Seconds 3
    }
    if ($with.Code -eq 200) { Say-Ok "The site answers from the internet at $site" }
    else { $failed++; Say-Fail "The site doesn't answer from the internet yet (code $($with.Code)). Wait a minute and run setup again; if it still fails, tell Warren." }
    $without = Invoke-Http 'GET' "$site/workshop.json" $null @{} 10
    if ($without.Code -eq 403) { Say-Ok 'and refuses anyone without the table''s key' }
    else { $failed++; Say-Fail "The site didn't refuse a visitor without the key (code $($without.Code)). Tell Warren." }

    # 4. The board has the table's file (the same check /hello runs).
    $npm = Join-Path (Split-Path (Get-Command node.exe).Source) 'npm.cmd'
    $hello = Invoke-Program $npm @('run', '--silent', 'hello') -WorkDir $TeamDir
    if ($hello.Code -eq 0) { Say-Ok 'The board has the table''s file' }
    else {
        $failed++
        Say-Fail 'The board hasn''t got the table''s file yet:'
        foreach ($line in ($hello.Output -split "`n" | Where-Object { $_ -match '^\s*FIX' })) { Write-Host "         $($line.Trim())" -ForegroundColor Red }
    }

    # 5. No key in anything setup wrote.
    $secrets = @([string]$Keys.token, [string]$Keys.anthropic_api_key, [string]$Keys.tunnel_token) | Where-Object { $_.Length -ge 8 }
    $files = @(Get-ChildItem $SetupDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 5MB -and $_.Extension -ne '.exe' }) +
             @(Get-ChildItem (Join-Path $TeamDir 'logs') -File -ErrorAction SilentlyContinue) +
             @(Get-Item (Join-Path $TeamDir 'TABLE.md'), (Join-Path $TeamDir 'workshop.json'), (Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName) -ErrorAction SilentlyContinue)
    $leaks = @()
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName)
        foreach ($s in $secrets) { if ($text.Contains($s)) { $leaks += $f.FullName } }
    }
    $taskXml = ''
    try { $taskXml = Export-ScheduledTask -TaskName $TaskName } catch {}
    foreach ($s in $secrets) { if ($taskXml.Contains($s)) { $leaks += "the $TaskName task" } }
    if ($leaks.Count -eq 0) { Say-Ok "No key appears in the log or any file setup wrote ($($files.Count) files checked)" }
    else { $failed++; Say-Fail "A key appears in: $(($leaks | Select-Object -Unique) -join ', '). Tell Warren." }

    return $failed
}

# ---------------------------------------------------------------------------

function Invoke-Setup {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    New-Item -ItemType Directory -Force -Path $SetupDir | Out-Null
    Write-Log "---- setup started on $env:COMPUTERNAME as $env:USERNAME"
    Write-Host ''
    Write-Host 'ARCA workshop: laptop setup' -ForegroundColor Cyan
    Write-Host 'Takes about 10 minutes. It asks for the table number and the admin password.'

    Assert-Ready
    $state = Read-State
    Invoke-NetworkCheck

    # The only questions, asked first, so nobody has to wait by the laptop.
    Say-Step 'Which table is this laptop?'
    $team = Read-TableNumber (Get-Prop $state 'team')
    $keys = Get-TableKeys $team
    Say-Ok "Got table $team's keys ($($keys.name)). Nothing else to answer: this takes about 10 minutes."

    $claude = Install-Programs $state
    $envChanged = Set-TableEnvironment $keys
    Install-TeamFolder $state $team
    Set-FolderOwner
    Set-ClaudeSettings ([string]$keys.anthropic_api_key)
    Install-Tunnel ([string]$keys.tunnel_token)
    Install-SiteTask $envChanged
    Set-PowerAndUpdates $state
    [void](Install-Shortcut $claude)
    $failed = Invoke-SelfTest $claude $keys
    Set-FolderOwner
    $keys = $null

    $minutes = [Math]::Round($clock.Elapsed.TotalMinutes, 1)
    Write-Host ''
    if ($failed -gt 0) {
        Say "NOT READY: $failed check(s) failed (red lines above). Fix them, then run setup again; it's safe to. ($minutes minutes)"
        return
    }
    Write-Host "READY: table $team is set up ($minutes minutes)." -ForegroundColor Green
    Write-Log "ready in $minutes minutes"
    Write-Host ''
    Write-Host 'Last step: Start workshop is opening now. When Claude Code appears, type ' -NoNewline
    Write-Host '/hello' -ForegroundColor Cyan -NoNewline
    Write-Host ' and press Enter.'
    Write-Host 'It should finish with "Look for your tile on the big screen". If Claude Code asks anything first, answer it once.'
    # Through Explorer, so Claude Code opens as the signed-in person, not as administrator.
    Start-Process explorer.exe -ArgumentList "`"$(Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName)`""
}

if (-not $env:ARCA_SETUP_NO_MAIN) {
    try { Invoke-Setup }
    catch {
        $msg = $_.Exception.Message
        Write-Host ''
        if ($msg -like 'SETUP-STOP:*') {
            Say-Fail $msg.Substring(11)
        } else {
            Write-Log "unexpected: $msg $($_.ScriptStackTrace)"
            Say-Fail "Setup stopped unexpectedly. Run it again; if it stops again, tell Warren. The details are in $LogFile."
        }
    }
}

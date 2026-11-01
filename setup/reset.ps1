# ARCA workshop: put the laptop back after the event
#
# Undoes setup.ps1: stops and removes the site task and the tunnel service,
# the table's settings and keys, Claude Code's settings and sign-in, the
# desktop shortcut and C:\Workshop (including the table's work). It puts the
# power settings back, turns Windows Update back on, and uninstalls the
# programs setup installed. Programs that were already on the laptop stay.
# Run it from an administrator PowerShell window:
#
#   irm https://raw.githubusercontent.com/warrenwoolhouse-cmd/arca-workshop-starter/main/setup/reset.ps1 | iex
#
# The keys themselves are revoked on the Anthropic Console and the admin page.
# Written for Windows PowerShell 5.1.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\Workshop'
$StateFile = 'C:\Workshop\setup\state.json'
$TaskName = 'ARCA workshop site'
$ShortcutName = 'Start workshop.lnk'
$EnvNames = @('ANTHROPIC_API_KEY', 'WORKSHOP_TEAM', 'WORKSHOP_TEAM_NAME', 'WORKSHOP_TEAM_TOKEN', 'WORKSHOP_SITE_URL', 'WORKSHOP_CENTRAL_URL')
$Packages = [ordered]@{ git = 'Git.Git'; node = 'OpenJS.NodeJS.LTS'; cloudflared = 'Cloudflare.cloudflared' }
$Problems = New-Object System.Collections.Generic.List[string]

function Say-Ok([string]$Text) { Write-Host '[  OK  ] ' -ForegroundColor Green -NoNewline; Write-Host $Text }
function Say-Fail([string]$Text) { Write-Host '[ FAIL ] ' -ForegroundColor Red -NoNewline; Write-Host $Text; $Problems.Add($Text) }

function Invoke-Quiet([string]$Exe, [string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & $Exe @Arguments 2>&1; return $LASTEXITCODE } finally { $ErrorActionPreference = $old }
}

function Get-Prop($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

function Invoke-Reset {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'This window isn''t running as administrator. Right-click Start, choose "Terminal (Admin)", and run reset again.' -ForegroundColor Red
        return
    }
    Write-Host ''
    Write-Host 'ARCA workshop: reset this laptop' -ForegroundColor Cyan
    Write-Host 'This deletes C:\Workshop, including everything the table made, and removes the workshop from this laptop.'
    if ((Read-Host 'Type RESET to go ahead') -cne 'RESET') { Write-Host 'Nothing changed.'; return }

    $state = $null
    try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch {}
    $installed = Get-Prop $state 'installed'

    # 1. The site and the tunnel.
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine -like "*$Root\*") -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Say-Ok 'Stopped the site and removed its scheduled task'

    if (Get-Service -Name Cloudflared -ErrorAction SilentlyContinue) {
        Stop-Service Cloudflared -Force -ErrorAction SilentlyContinue
        $cf = $null
        try { $cf = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared').ImagePath -replace '^"([^"]+)".*$', '$1') } catch {}
        if ($cf -and (Test-Path $cf)) { [void](Invoke-Quiet $cf @('service', 'uninstall')) }
        if (Get-Service -Name Cloudflared -ErrorAction SilentlyContinue) { [void](Invoke-Quiet 'sc.exe' @('delete', 'Cloudflared')) }
    }
    Say-Ok 'Removed the tunnel service'

    # 2. The table's settings and keys.
    foreach ($n in $EnvNames) { [Environment]::SetEnvironmentVariable($n, $null, 'User') }
    Say-Ok 'Removed the table''s settings and keys'

    # 3. Claude Code's settings, sign-in and history.
    foreach ($p in @((Join-Path $env:USERPROFILE '.claude'), (Join-Path $env:USERPROFILE '.claude.json'))) {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    }
    Get-ChildItem $env:USERPROFILE -Filter '.claude.json.*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force
    Say-Ok 'Removed Claude Code''s settings and sign-in'

    # 4. The shortcut.
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
    Say-Ok 'Removed the Start workshop shortcut'

    # 5. Power settings back as they were (Windows defaults if setup didn't record them).
    $before = Get-Prop $state 'power_before'
    $defaults = @{ 'SUB_SLEEP/STANDBYIDLE' = @(1800, 900); 'SUB_SLEEP/HIBERNATEIDLE' = @(0, 0); 'SUB_VIDEO/VIDEOIDLE' = @(600, 300); 'SUB_BUTTONS/LIDACTION' = @(1, 1) }
    foreach ($name in $defaults.Keys) {
        $sub, $setting = $name -split '/'
        $v = Get-Prop $before $name
        $ac = if ($v) { $v.ac } else { $defaults[$name][0] }
        $dc = if ($v -and $null -ne (Get-Prop $v 'dc')) { $v.dc } else { $defaults[$name][1] }
        [void](Invoke-Quiet 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', $sub, $setting, "$ac"))
        [void](Invoke-Quiet 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', $sub, $setting, "$dc"))
    }
    [void](Invoke-Quiet 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT'))
    Say-Ok 'Put the sleep, screen and lid settings back'

    $wu = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    if (Get-Prop $state 'paused_updates') {
        foreach ($n in 'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime') {
            Remove-ItemProperty -Path $wu -Name $n -ErrorAction SilentlyContinue
        }
        Say-Ok 'Turned Windows Update back on'
    }

    # 6. Programs setup installed (and only those).
    if (Get-Prop $installed 'claude') {
        Remove-Item (Join-Path $env:USERPROFILE '.local\bin\claude.exe') -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:USERPROFILE '.local\share\claude') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:USERPROFILE '.local\state\claude') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:USERPROFILE '.cache\claude') -Recurse -Force -ErrorAction SilentlyContinue
        $bin = Join-Path $env:USERPROFILE '.local\bin'
        if ((Test-Path $bin) -and -not (Get-ChildItem $bin -Force)) { Remove-Item $bin -Force }
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath) {
            $kept = @($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $bin })
            [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
        }
        Say-Ok 'Uninstalled Claude Code'
    }
    foreach ($key in $Packages.Keys) {
        if (-not (Get-Prop $installed $key)) { continue }
        $code = Invoke-Quiet 'winget.exe' @('uninstall', '--id', $Packages[$key], '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity')
        if ($code -eq 0) { Say-Ok "Uninstalled $key" } else { Say-Fail "Couldn't uninstall $key (winget said $code). Remove it in Settings, Apps." }
    }
    if (Get-Prop $installed 'node') {
        foreach ($p in @((Join-Path $env:LOCALAPPDATA 'npm-cache'), (Join-Path $env:APPDATA 'npm'))) {
            if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # 7. The folder, last: it held the record of what to undo.
    if (Test-Path $Root) {
        Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $Root) { Start-Sleep -Seconds 3; Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # What's left, if anything.
    Write-Host ''
    Write-Host 'Checking nothing is left' -ForegroundColor Cyan
    if (Test-Path $Root) { Say-Fail "$Root is still there (a file in it is in use). Restart the laptop and delete it." } else { Say-Ok "$Root is gone" }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Say-Fail 'The site''s scheduled task is still there.' } else { Say-Ok 'No scheduled task' }
    if (Get-Service -Name Cloudflared -ErrorAction SilentlyContinue) { Say-Fail 'The tunnel service is still there.' } else { Say-Ok 'No tunnel service' }
    $left = @($EnvNames | Where-Object { [Environment]::GetEnvironmentVariable($_, 'User') })
    if ($left.Count) { Say-Fail "Settings still there: $($left -join ', ')" } else { Say-Ok 'No table settings or keys' }
    if ((Test-Path (Join-Path $env:USERPROFILE '.claude')) -or (Test-Path (Join-Path $env:USERPROFILE '.claude.json'))) { Say-Fail 'Claude Code''s settings are still there.' } else { Say-Ok 'No Claude Code settings or sign-in' }
    if (Test-Path $lnk) { Say-Fail 'The shortcut is still on the desktop.' } else { Say-Ok 'No shortcut' }

    Write-Host ''
    if ($Problems.Count) { Write-Host "DONE, WITH $($Problems.Count) THING(S) TO FINISH BY HAND (red lines above)." -ForegroundColor Yellow }
    else { Write-Host 'DONE: the workshop is gone from this laptop. Revoke its keys on the Anthropic Console if you haven''t.' -ForegroundColor Green }
}

try { Invoke-Reset }
catch { Write-Host "Reset stopped unexpectedly: $($_.Exception.Message). Run it again." -ForegroundColor Red }

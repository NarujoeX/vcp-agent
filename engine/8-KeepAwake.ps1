# 8-KeepAwake.ps1 - holds the machine out of idle sleep for the US session.
# The stop watch is the stop; a sleeping machine has no stop. Run it from the
# scheduler at 22:25 SGT, or start it by hand before the session.
#
#   powershell -File engine\8-KeepAwake.ps1 -Status      # power source and sleep timeouts
#   powershell -File engine\8-KeepAwake.ps1 -Hold        # hold for 10.75 h (22:25 -> 09:10 SGT)
#   powershell -File engine\8-KeepAwake.ps1 -Hold -Hours 6.5
#
# A hold blocks idle sleep on AC and on battery. It does not override a lid close,
# a Windows Update restart or a dead battery.
[CmdletBinding()]
param(
    [switch]$Hold,
    [switch]$Status,
    [double]$Hours = 10.75
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"

Add-Type -Namespace KeepAwake -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1

function Get-PowerSource {
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $b) { return 'desktop (no battery)' }
    # BatteryStatus 2 = AC power
    if ([int]$b.BatteryStatus -eq 2) { return ('AC, {0}% charged' -f $b.EstimatedChargeRemaining) }
    return ('battery, {0}% left' -f $b.EstimatedChargeRemaining)
}

function Get-SleepTimeout {
    param([string]$Alias, [string]$Subgroup)
    $out = powercfg -q SCHEME_CURRENT $Subgroup $Alias 2>&1 | Out-String
    $ac = [regex]::Match($out, 'Current AC Power Setting Index: 0x([0-9a-fA-F]+)')
    $dc = [regex]::Match($out, 'Current DC Power Setting Index: 0x([0-9a-fA-F]+)')
    $fmt = {
        param($m)
        if (-not $m.Success) { return 'unknown' }
        $s = [Convert]::ToInt32($m.Groups[1].Value, 16)
        if ($s -eq 0) { 'never' } else { "$([math]::Round($s / 60)) min" }
    }
    [pscustomobject]@{ ac = (& $fmt $ac); dc = (& $fmt $dc) }
}

function Show-Status {
    $sleep = Get-SleepTimeout -Alias 'STANDBYIDLE' -Subgroup 'SUB_SLEEP'
    $hib = Get-SleepTimeout -Alias 'HIBERNATEIDLE' -Subgroup 'SUB_SLEEP'
    $marker = Get-Path 'state\keepawake.json'
    Write-Output ("power      : " + (Get-PowerSource))
    Write-Output ("sleep      : AC {0}, battery {1}" -f $sleep.ac, $sleep.dc)
    Write-Output ("hibernate  : AC {0}, battery {1}" -f $hib.ac, $hib.dc)
    if (Test-Path $marker) {
        $m = Read-JsonFile $marker
        $alive = $null -ne (Get-Process -Id ([int]$m.pid) -ErrorAction SilentlyContinue)
        Write-Output ("hold       : {0} until {1} (pid {2})" -f $(if ($alive) { 'ACTIVE' } else { 'stale marker' }), $m.until, $m.pid)
        if (-not $alive) { Remove-Item -Force $marker -ErrorAction SilentlyContinue }
    }
    else { Write-Output 'hold       : not running' }
    Write-Output 'gaps       : lid close, Windows Update restart, unplugged battery'
}

if ($Status -or -not $Hold) {
    Show-Status
    if (-not $Hold) { Write-Output 'Dry: add -Hold to start the session hold.' }
    exit 0
}

$power = Get-PowerSource
Write-Log ("keep-awake hold starting for {0} h; power: {1}" -f $Hours, $power)
if ($power -notlike 'AC*' -and $power -notlike 'desktop*') {
    Write-Log 'running on battery: plug in, a drained battery ends the session' $null 'WARN'
}

$marker = Get-Path 'state\keepawake.json'
$until = (Get-Date).AddHours($Hours)
Write-JsonFile -Object ([pscustomobject]@{ pid = $PID; started = (Get-Date).ToString('o'); until = $until.ToString('o'); hours = $Hours }) -Path $marker

try {
    while ((Get-Date) -lt $until) {
        [KeepAwake.Native]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
        $left = [math]::Max(1, [math]::Min(60, [int](($until - (Get-Date)).TotalSeconds) + 1))
        Start-Sleep -Seconds $left
    }
}
finally {
    [KeepAwake.Native]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    Remove-Item -Force $marker -ErrorAction SilentlyContinue
    Write-Log 'keep-awake hold released'
}

# 9-Schedule.ps1
# Registers the Windows Scheduled Tasks that run the agent inside US market hours.
# Nothing is registered unless you pass -Install.
#
#   powershell -File engine\9-Schedule.ps1              # show what would be registered
#   powershell -File engine\9-Schedule.ps1 -Install     # dry-run cycles (no orders)
#   powershell -File engine\9-Schedule.ps1 -Install -Live   # cycles may place orders
#   powershell -File engine\9-Schedule.ps1 -Remove
#
# Times are local (SGT). US winter session: pre-market 17:00, regular 22:30-05:00,
# after-hours 05:00-09:00. The scripts re-check the ET session on every run, so a
# holiday or a closed market is a no-op, never an order.
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Live,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"

$engine = (Get-Path 'engine')
$ps = 'powershell.exe'
$cycleArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$engine\Invoke-Cycle.ps1`""
if ($Live) { $cycleArgs += ' -Execute' }
# Friday's US session ends on Saturday morning SGT, so the end-of-day tasks need Saturday.
$weekdays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
$allDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')

$tasks = @(
    @{
        name = 'VCP-Agent-Cycle'
        desc = 'VCP agent: 15-minute trade cycles during the US session'
        args = $cycleArgs
        at   = '22:29'
        every = 15
        forHours = 6.5
        weekdays = $true
    },
    @{
        name = 'VCP-Agent-StopWatch'
        desc = 'VCP agent: 60-second protective stop watch (market sells on breach)'
        args = "-NoProfile -ExecutionPolicy Bypass -File `"$engine\6-StopWatch.ps1`" -Loop"
        at   = '22:29'
        every = 1
        forHours = 10.5
        weekdays = $true
    },
    @{
        name = 'VCP-Agent-EOD'
        desc = 'VCP agent: end-of-day kline refresh, scan and dashboard'
        args = "-NoProfile -ExecutionPolicy Bypass -File `"$engine\1-Refresh-Universe.ps1`" -TopN 500"
        at   = '05:15'
        every = 0
        forHours = 0
        weekdays = $false
        days = $allDays
    },
    @{
        name = 'VCP-Agent-KeepAwake'
        desc = 'VCP agent: hold the machine out of sleep for the US session (the stop watch is the stop)'
        args = "-NoProfile -ExecutionPolicy Bypass -File `"$engine\8-KeepAwake.ps1`" -Hold -Hours 10.75"
        at   = '22:25'
        every = 0
        forHours = 0
        weekdays = $true
    },
    @{
        name = 'VCP-Agent-Shutdown'
        desc = 'VCP agent: power the laptop off after the end-of-day refresh (flat only; otherwise the 09:05 run)'
        args = "-NoProfile -ExecutionPolicy Bypass -File `"$engine\10-Shutdown.ps1`" -Execute"
        at   = '05:20'
        every = 0
        forHours = 0
        weekdays = $false
        days = $allDays
        wake = $false
    },
    @{
        name = 'VCP-Agent-Shutdown-Late'
        desc = 'VCP agent: power the laptop off once after-hours ends and the stop watch stops (20:00 ET)'
        args = "-NoProfile -ExecutionPolicy Bypass -File `"$engine\10-Shutdown.ps1`" -Execute"
        at   = '09:05'
        every = 0
        forHours = 0
        weekdays = $false
        days = $allDays
        wake = $false
    }
)

if ($Remove) {
    foreach ($t in $tasks) {
        $existing = Get-ScheduledTask -TaskName $t.name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $t.name -Confirm:$false
            Write-Output ("removed {0}" -f $t.name)
        }
        else { Write-Output ("not found {0}" -f $t.name) }
    }
    exit 0
}

if (-not $Install) {
    Write-Output 'DRY PREVIEW — nothing registered. Add -Install (and -Live to allow orders).'
    foreach ($t in $tasks) {
        $rep = if ($t.every -gt 0) { " repeat every $($t.every) min for $($t.forHours) h" } else { '' }
        $taskDays = if ($t.ContainsKey('days')) { $t.days } else { $weekdays }
        $dayLabel = if ($taskDays.Count -ge 6) { 'Mon-Sat' } else { 'Mon-Fri' }
        Write-Output ("  {0,-24} {1} {2}{3}" -f $t.name, $dayLabel, $t.at, $rep)
        Write-Output ("    {0}" -f $t.args)
    }
    exit 0
}

$user = "$env:USERDOMAIN\$env:USERNAME"
foreach ($t in $tasks) {
    $taskDays = if ($t.ContainsKey('days')) { $t.days } else { $weekdays }
    # A shutdown task must never wake the machine just to power it off.
    $wake = if ($t.ContainsKey('wake')) { [bool]$t.wake } else { $true }
    $action = New-ScheduledTaskAction -Execute $ps -Argument $t.args -WorkingDirectory (Get-RepoRoot)
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $taskDays -At $t.at
    if ($t.every -gt 0) {
        # Repetition has to come from a -Once trigger object; assigning it to the weekly
        # trigger is the supported way to get "every N minutes for M hours" in PS 5.1.
        $once = New-ScheduledTaskTrigger -Once -At $t.at `
            -RepetitionInterval (New-TimeSpan -Minutes $t.every) `
            -RepetitionDuration (New-TimeSpan -Hours ([int]$t.forHours) -Minutes ([int](($t.forHours - [int]$t.forHours) * 60)))
        $trigger.Repetition = $once.Repetition
    }
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $setArgs = @{
        StartWhenAvailable      = $true
        AllowStartIfOnBatteries = $true
        DontStopIfGoingOnBatteries = $true
        MultipleInstances       = 'IgnoreNew'
        ExecutionTimeLimit      = (New-TimeSpan -Hours 12)
    }
    if ($wake) { $setArgs.WakeToRun = $true }
    $settings = New-ScheduledTaskSettingsSet @setArgs

    $existing = Get-ScheduledTask -TaskName $t.name -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $t.name -Confirm:$false }
    Register-ScheduledTask -TaskName $t.name -Description $t.desc -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
    Write-Output ("registered {0}" -f $t.name)
}
Write-Output ''
Write-Output 'Check with:  schtasks /query /tn VCP-Agent-Cycle /v /fo LIST'
if (-not $Live) { Write-Output 'NOTE: cycle task is in dry-run mode. Re-run with -Install -Live to send orders.' }

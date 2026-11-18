# 10-Shutdown.ps1 - powers the machine off once the end-of-day refresh has finished.
# Runs from the scheduler at 05:20 and 09:05 SGT (Mon-Sat), after VCP-Agent-EOD at 05:15.
# At 05:20 it powers off only when flat: with a position open the stop watch keeps enforcing
# until after-hours ends at 20:00 ET, and the 09:05 run does the shutdown.
#
#   powershell -File engine\10-Shutdown.ps1                # report only, never shuts down
#   powershell -File engine\10-Shutdown.ps1 -Execute       # shut down after EOD succeeds
#   powershell -File engine\10-Shutdown.ps1 -Execute -IgnoreEodFailure
#   powershell -File engine\10-Shutdown.ps1 -Execute -Force   # ignore window and EOD checks
#
# Refuses to shut down while the EOD task is still running, or when the last EOD run
# failed - a dead machine hides a stale refresh until the next evening.
[CmdletBinding()]
param(
    [switch]$Execute,
    [int]$DelaySeconds = 120,
    [int]$WaitMinutes = 45,
    [switch]$IgnoreEodFailure,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"

$c = Get-Config
$eodName = 'VCP-Agent-EOD'

# A missed 05:20 run replays when the machine next starts (StartWhenAvailable), which would
# power the laptop off the moment it is switched on for the evening session.
$now = Get-Date
if (-not $Force -and ($now.Hour -lt 4 -or $now.Hour -ge 12)) {
    throw ("local time {0:HH:mm} is outside the 04:00-12:00 power-off window; not powering off. Use -Force to override." -f $now)
}

function Get-EodStatus {
    $t = Get-ScheduledTask -TaskName $eodName -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $info = Get-ScheduledTaskInfo -TaskName $eodName
    [pscustomobject]@{
        state  = [string]$t.State
        result = [int]$info.LastTaskResult
        last   = $info.LastRunTime
    }
}

function Get-OpenPositionLines {
    $resp = Invoke-Moomoo -Arguments @('sim', 'position', '--account', $c.account.account_id, '--market', $c.account.market)
    $raw = Get-Prop $resp 'positions' (Get-Prop $resp 'position_list' @())
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($raw)) {
        if ($null -eq $p) { continue }
        $qty = To-Num (Get-Prop $p 'qty' 0)
        if ($qty -le 0) { continue }
        $sym = [string](Get-Prop $p 'code' (Get-Prop $p 'symbol' ''))
        if ($sym -and $sym -notmatch '^US\.') { $sym = "US.$sym" }
        $lines.Add(("{0} x{1}" -f $sym, $qty))
    }
    $lines
}

# --- wait for the refresh to finish --------------------------------------
$deadline = (Get-Date).AddMinutes($WaitMinutes)
while ($true) {
    $eod = Get-EodStatus
    if (-not $eod) { Write-Log "$eodName is not registered; nothing to wait for" $null 'WARN'; break }
    if ($eod.state -ne 'Running') { break }
    if ((Get-Date) -gt $deadline) { throw "$eodName still running after $WaitMinutes min; not shutting down" }
    Write-Output "waiting for $eodName to finish..."
    Start-Sleep -Seconds 20
}
if ($eod) { Write-Log ("EOD state={0} lastResult={1} lastRun={2}" -f $eod.state, $eod.result, $eod.last) }

# A refresh that never ran today leaves the scan on yesterday's bars; stay on so it is visible.
$ranToday = $eod -and ($eod.last -ge (Get-Date).Date)
if (-not $ranToday -and -not ($IgnoreEodFailure -or $Force)) {
    throw "EOD has not run today (last run $($eod.last)); not powering off. Pass -IgnoreEodFailure to override."
}

# A stale LastTaskResult from an older day must not block tonight.
$fresh = $eod -and ((Get-Date) - $eod.last).TotalHours -lt 3
if ($fresh -and $eod.result -ne 0 -and -not ($IgnoreEodFailure -or $Force)) {
    throw ("EOD finished with result {0}; refusing to power off. Rerun 1-Refresh-Universe.ps1, or pass -IgnoreEodFailure." -f $eod.result)
}

# --- record what is still open (nothing protects it once the machine is off)
$session = Get-SessionState
try {
    $open = @(Get-OpenPositionLines)
    if ($open.Count -gt 0 -and (Test-ProtectionWindow $session) -and -not $Force) {
        Write-Log ("{0} position(s) open ({1}); the {2} session runs to 20:00 ET and the stop watch needs this machine. Staying on - the 09:05 run powers off." -f $open.Count, ($open -join ', '), $session.session) $null 'WARN'
        exit 0
    }
    if ($open.Count -gt 0) {
        Write-Log ("open positions carried overnight: " + ($open -join ', ')) $null 'WARN'
    }
    else { Write-Log 'flat: no open positions carried overnight' }
}
catch {
    Write-Log ("could not read positions: " + $_.Exception.Message) $null 'WARN'
}

# --- shut down -----------------------------------------------------------
$when = (Get-Date).AddSeconds($DelaySeconds)
if (-not $Execute) {
    Write-Output ("DRY: would shut down at {0} (in {1}s). Add -Execute." -f $when.ToString('HH:mm:ss'), $DelaySeconds)
    exit 0
}

$msg = "VCP-Agent: end-of-day refresh complete. Powering off; cancel with 'shutdown /a'."
Write-Log ("shutting down at {0} (in {1}s)" -f $when.ToString('HH:mm:ss'), $DelaySeconds)
& shutdown.exe /s /t $DelaySeconds /c $msg
exit $LASTEXITCODE

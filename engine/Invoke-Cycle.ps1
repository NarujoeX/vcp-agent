# Invoke-Cycle.ps1
# One trade cycle. Safe by default: nothing is sent to the broker unless -Execute.
#
#   powershell -File engine\Invoke-Cycle.ps1                # dry run
#   powershell -File engine\Invoke-Cycle.ps1 -Execute       # places approved orders
#   powershell -File engine\Invoke-Cycle.ps1 -Force         # ignore session gate (manual)
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$Force,
    [switch]$SkipStops,
    [switch]$SkipScan
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/Common.ps1"

$cfg = Get-Config
$session = Get-SessionState

$run = Join-Path (Get-Path 'runs') ((Get-Date -Format 'yyyyMMdd-HHmmss'))
Ensure-Dir $run | Out-Null
$cycleLog = Join-Path $run 'cycle.log'

function Step([string]$Name, [scriptblock]$Body) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $msg = "$stamp [$Name] start"
    Write-Host $msg
    Add-Content -Path $cycleLog -Value $msg
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $out = & $Body 2>&1
        foreach ($line in @($out)) { Add-Content -Path $cycleLog -Value ("    " + ([string]$line)) }
        $done = (Get-Date -Format 'HH:mm:ss') + " [$Name] done in $([int]$sw.Elapsed.TotalSeconds)s"
        Write-Host $done
        Add-Content -Path $cycleLog -Value $done
        return $out
    }
    catch {
        $sw.Stop()
        $err = (Get-Date -Format 'HH:mm:ss') + " [$Name] FAILED: " + $_.Exception.Message
        Write-Host $err
        Add-Content -Path $cycleLog -Value $err
        if ($_.ScriptStackTrace) { Add-Content -Path $cycleLog -Value $_.ScriptStackTrace }
        return @()
    }
}

Write-Host ("=" * 64)
Write-Host ("cycle " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  session=" + $session.session + "  open=" + $session.open)
Write-Host ("account " + $cfg.account.account_id + "  market " + $cfg.account.market + "  execute=" + $Execute.IsPresent)
Write-Host ("=" * 64)

if (-not $Force -and -not $session.open) {
    Write-Host "Market closed ($($session.session)). Nothing to do."
    exit 0
}
$isRegular = ($session.session -eq 'regular')
if (-not $Force -and -not $isRegular) {
    Write-Host "Outside regular hours ($($session.session)). No new entries; exits handled by StopWatch."
}

$entriesAllowed = $isRegular -and -not (Test-PastFlattenDeadline) -and -not (Test-NoNewEntries)

# 1. Protect open positions first.
if (-not $SkipStops) {
    Step 'stopwatch' {
        & (Get-Path 'engine\6-StopWatch.ps1') -Force -DryRun:(-not $Execute) | Out-String
    } | Out-Null
}

# 2. Reconcile broker truth.
Step 'reconcile' {
    & (Get-Path 'engine\3-Reconcile.ps1') | Out-String
} | Out-Null

# 3. Scan the universe for VCP setups.
if (-not $SkipScan) {
    Step 'scan' {
        & (Get-Path 'engine\2-Scan-Vcp.ps1') | Out-String
    } | Out-Null
}

# 4. Scout proposes (never trades).
$propArgs = @{ AllowBuy = $entriesAllowed }
Step 'propose' {
    & (Get-Path 'engine\4-Propose.ps1') @propArgs | Out-String
} | Out-Null

# 5. Guard executes approved proposals.
$execArgs = @{}
if ($Execute) { $execArgs.Execute = $true }
Step 'execute' {
    & (Get-Path 'engine\5-Execute.ps1') @execArgs | Out-String
} | Out-Null

# 6. Refresh dashboard.
Step 'dashboard' {
    & (Get-Path 'engine\Build-Dashboard.ps1') | Out-String
} | Out-Null

$latest = Read-JsonFile (Get-Path 'state\proposals-latest.json')
$ap = @($latest.ranked | Where-Object { $_.approved })
$rj = @($latest.ranked | Where-Object { -not $_.approved })

Write-Host ""
Write-Host "--- cycle summary ---"
Write-Host ("approved : " + $ap.Count + "  " + (($ap | ForEach-Object { $_.symbol + '(' + $_.qty + '@' + $_.entry + ')' }) -join ', '))
Write-Host ("rejected : " + $rj.Count)
foreach ($r in ($rj | Select-Object -First 6)) {
    $why = ($r.violations | ForEach-Object { $_.rule }) -join ','
    Write-Host ("   " + $r.symbol.PadRight(6) + " " + $why)
}
Write-Host ("log: " + $cycleLog)
if (-not $Execute) { Write-Host "DRY RUN — no orders sent. Add -Execute to trade." }

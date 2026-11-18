# Common.ps1 - shared helpers for the VCP engine.
# Dot-source this from every engine script:  . "$PSScriptRoot/lib/Common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MoomooExe = if ($env:MOOMOO_EXE) { $env:MOOMOO_EXE } elseif (Test-Path 'C:\Users\REDACTED_USER\AppData\Local\MoomooCLI\bin\moomoo.exe') { 'C:\Users\REDACTED_USER\AppData\Local\MoomooCLI\bin\moomoo.exe' } else { 'moomoo' }

function Get-RepoRoot {
    param([string]$Start = $PSScriptRoot)
    $d = Get-Item $Start
    while ($d -and -not (Test-Path (Join-Path $d.FullName 'config\config.json'))) {
        $d = $d.Parent
    }
    if (-not $d) { throw "Could not locate repo root (config\config.json) above $PSScriptRoot" }
    $d.FullName
}

$script:Root = Get-RepoRoot
$script:ConfigCache = $null

function Get-Config {
    if (-not $script:ConfigCache) {
        $script:ConfigCache = Get-Content (Join-Path $script:Root 'config\config.json') -Raw | ConvertFrom-Json
    }
    $script:ConfigCache
}

function Get-Rulebook {
    Get-Content (Join-Path $script:Root 'strategy\rules.json') -Raw | ConvertFrom-Json
}

function Get-Path {
    param([string]$Child)
    Join-Path $script:Root $Child
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $Path
}

function Get-Stamp {
    Get-Date -Format 'yyyyMMdd-HHmmss'
}

function New-RunDir {
    param([string]$Tag = 'cycle')
    $stamp = Get-Stamp
    $dir = Get-Path ("runs\" + (Get-Date -Format 'yyyy-MM-dd') + "\$stamp-$Tag")
    Ensure-Dir $dir | Out-Null
    Ensure-Dir (Join-Path $dir 'raw') | Out-Null
    $dir
}

function Write-Log {
    param([string]$Message, [string]$RunDir, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($RunDir) { Add-Content -Path (Join-Path $RunDir 'engine.log') -Value $line }
}

function Write-JsonFile {
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)][string]$Path, [switch]$Compact)
    $dir = Split-Path $Path -Parent
    if ($dir) { Ensure-Dir $dir | Out-Null }
    $tmp = "$Path.tmp"
    $depth = 20
    if ($Compact) { $Object | ConvertTo-Json -Depth $depth -Compress | Set-Content -Path $tmp -Encoding UTF8 }
    else { $Object | ConvertTo-Json -Depth $depth | Set-Content -Path $tmp -Encoding UTF8 }
    Move-Item -Force $tmp $Path
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    Get-Content $Path -Raw | ConvertFrom-Json
}

function Add-Jsonl {
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path $Path -Parent
    if ($dir) { Ensure-Dir $dir | Out-Null }
    $line = $Object | ConvertTo-Json -Depth 20 -Compress
    Add-Content -Path $Path -Value $line -Encoding UTF8
}

function Read-Jsonl {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    @(Get-Content $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function To-Num {
    param($Value, [double]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $d = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    $Default
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    $Default
}

function To-EtDate {
    param([datetimeoffset]$At)
    [System.TimeZoneInfo]::ConvertTime($At, [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time'))
}

# --- Moomoo CLI wrapper ---------------------------------------------------
# Every API call goes through here: retried, logged, JSON-parsed.
# Order writes are never performed unless -Execute is passed by the caller.
function Invoke-Moomoo {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$RunDir,
        [int]$Retries = 5,
        [int]$ThrottleMs = 120
    )
    $argList = @($Arguments | ForEach-Object { ([string]$_) -replace '"', '\"' }) + @('-f', 'json')
    $attempt = 0
    while ($true) {
        $attempt++
        if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
        Write-Log ("moomoo " + ($Arguments -join ' ')) $RunDir
        $out = & $script:MoomooExe @argList 2>&1 | Out-String
        $ok = ($LASTEXITCODE -eq 0 -and $out.Trim())
        if ($ok) {
            try { return ($out | ConvertFrom-Json) }
            catch { Write-Log "Non-JSON output: $($out.Substring(0,[math]::Min(200,$out.Length)))" $RunDir 'WARN' }
        }
        if ($attempt -gt $Retries) {
            throw ("moomoo failed after {0} attempts: {1} :: {2}" -f $attempt, ($Arguments -join ' '), $out.Trim())
        }
        $limited = $out -match '439|429|rate limit|too many|frequen'
        $wait = if ($limited) {
            $m = [regex]::Match($out, 'retry after (\d+)\s*s', 'IgnoreCase')
            if ($m.Success) { [int]$m.Groups[1].Value + 2 } else { [math]::Min(60, 10 * $attempt) }
        } else { 2 * $attempt }
        Write-Log ("retry {0} in {1}s ({2})" -f $attempt, $wait, $(if ($limited) { 'rate limited' } else { 'error' })) $RunDir 'WARN'
        Start-Sleep -Seconds $wait
    }
}

function Save-Raw {
    param($Object, [string]$RunDir, [string]$Name)
    if ($RunDir -and $Object) { Write-JsonFile -Object $Object -Path (Join-Path $RunDir ("raw\$Name.json")) }
}

# --- Market calendar ------------------------------------------------------
function Get-EtNow {
    $utc = [datetimeoffset]::UtcNow
    [System.TimeZoneInfo]::ConvertTime($utc, [System.TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time'))
}

function Get-SessionState {
    param([datetimeoffset]$EtNow = (Get-EtNow))
    $c = Get-Config
    $date = $EtNow.ToString('yyyy-MM-dd')
    $t = $EtNow.TimeOfDay

    if ($c.competition.closed_dates -contains $date) { return @{ open = $false; session = 'closed'; reason = 'market holiday' } }
    if ($EtNow.DayOfWeek -in @('Saturday', 'Sunday')) { return @{ open = $false; session = 'closed'; reason = 'weekend' } }
    if ($EtNow -gt [datetimeoffset]::Parse($c.competition.end)) { return @{ open = $false; session = 'closed'; reason = 'competition ended' } }
    if ($EtNow -lt [datetimeoffset]::Parse($c.competition.start + 'T00:00:00-05:00')) { return @{ open = $false; session = 'closed'; reason = 'competition not started' } }

    $isHalfDay = $c.competition.half_days -contains $date
    $closeTime = if ($isHalfDay) { [TimeSpan]'13:00:00' } else { [TimeSpan]'16:00:00' }

    if ($t -ge [TimeSpan]'09:30:00' -and $t -lt $closeTime) { return @{ open = $true; session = 'regular'; reason = 'RTH'; halfDay = $isHalfDay } }
    if ($t -lt [TimeSpan]'09:30:00' -and $t -ge [TimeSpan]'04:00:00') { return @{ open = $false; session = 'premarket'; reason = 'pre-market: plan only' } }
    if ($t -ge $closeTime -and $t -lt [TimeSpan]'20:00:00') { return @{ open = $false; session = 'afterhours'; reason = 'after-hours: exits only' } }
    return @{ open = $false; session = 'closed'; reason = 'outside session' }
}

# Stops are enforced in the regular session and again in after-hours. Outside RTH the paper
# API takes limit orders only, so the stop watch crosses with a limit instead of a market order.
function Test-ProtectionWindow {
    param($Session = (Get-SessionState))
    @('regular', 'afterhours') -contains [string]$Session.session
}

function Test-NoNewEntries {
    param([datetimeoffset]$EtNow = (Get-EtNow))
    $c = Get-Config
    $from = [datetimeoffset]::Parse($c.competition.no_new_entries_from + 'T00:00:00-05:00')
    if ($EtNow -ge $from) { return $true }
    if ($c.competition.half_days -contains $EtNow.ToString('yyyy-MM-dd')) { return $true }
    $false
}

function Test-PastFlattenDeadline {
    param([datetimeoffset]$EtNow = (Get-EtNow))
    $c = Get-Config
    $EtNow -ge [datetimeoffset]::Parse($c.competition.flatten_deadline)
}

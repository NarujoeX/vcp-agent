$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\engine\lib\Common.ps1"
. "$PSScriptRoot\..\engine\lib\Gate.ps1"

$script:pass = 0; $script:fail = 0
function Check($name, $cond) {
    if ($cond) { $script:pass++; Write-Output "PASS  $name" } else { $script:fail++; Write-Output "FAIL  $name" }
}

$rb = Get-Rulebook
$before = [datetimeoffset]::Parse('2026-11-18T10:00:00-05:00')
$after = [datetimeoffset]::Parse('2026-11-19T10:00:00-05:00')
$open = [datetimeoffset]::Parse('2026-11-20T10:00:00-05:00')

Check 'before fallback_from, 0 traded -> no fallback' (-not (Test-JLawFallback -TradedCount 0 -EtNow $before -Rulebook $rb))
Check 'fallback_from day, 5 traded -> no fallback (count met)' (-not (Test-JLawFallback -TradedCount 5 -EtNow $after -Rulebook $rb))
Check 'fallback_from day, 3 traded -> no fallback (at minimum)' (-not (Test-JLawFallback -TradedCount 3 -EtNow $after -Rulebook $rb))
Check 'fallback_from day, 2 traded -> fallback' (Test-JLawFallback -TradedCount 2 -EtNow $after -Rulebook $rb)
Check 'after, 0 traded -> fallback' (Test-JLawFallback -TradedCount 0 -EtNow $open -Rulebook $rb)
$disabled = $rb | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$disabled.jlaw.enabled = $false
Check 'jlaw disabled -> never fallback' (-not (Test-JLawFallback -TradedCount 0 -EtNow $open -Rulebook $disabled))

Write-Output "RESULT pass=$pass fail=$fail"
if ($fail -gt 0) { exit 1 }

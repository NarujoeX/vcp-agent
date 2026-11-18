# Data.ps1 - disk cache for universe and bars.

function ConvertTo-Bars {
    param($KlineList)
    $bars = New-Object System.Collections.Generic.List[object]
    foreach ($k in @($KlineList)) {
        $bars.Add([pscustomobject]@{
            date   = [int]$k.date
            open   = To-Num $k.open_price
            high   = To-Num $k.high_price
            low    = To-Num $k.low_price
            close  = To-Num $k.close_price
            volume = To-Num $k.volume
        })
    }
    , $bars.ToArray()
}

function Get-KlinePath {
    param([string]$Symbol)
    Get-Path ("data\klines\" + ($Symbol -replace '\.', '_') + ".json")
}

function Save-Klines {
    param([string]$Symbol, $KlineList, [string]$Name)
    $path = Get-KlinePath $Symbol
    $bars = ConvertTo-Bars $KlineList
    Write-JsonFile -Object ([pscustomobject]@{
            symbol = $Symbol
            name   = $Name
            saved  = (Get-Date -Format 's')
            count  = $bars.Count
            bars   = $bars
        }) -Path $path -Compact
    $path
}

function Load-Klines {
    param([string]$Symbol)
    $path = Get-KlinePath $Symbol
    if (-not (Test-Path $path)) { return $null }
    $doc = Read-JsonFile $path
    if (-not $doc -or -not $doc.bars) { return $null }
    return , ([object[]]$doc.bars)
}

function Get-KlineAge {
    param([string]$Symbol)
    $p = Get-KlinePath $Symbol
    if (-not (Test-Path $p)) { return [timespan]::MaxValue }
    (Get-Date) - (Get-Item $p).LastWriteTime
}

function Load-Universe {
    $p = Get-Path 'data\universe\universe.json'
    Read-JsonFile $p
}

function Save-Universe {
    param($Universe)
    Write-JsonFile -Object $Universe -Path (Get-Path 'data\universe\universe.json')
}

function Get-LatestPortfolioState {
    Read-JsonFile (Get-Path 'state\portfolio.json')
}

function Save-PortfolioState {
    param($State)
    Write-JsonFile -Object $State -Path (Get-Path 'state\portfolio.json')
}

# Catalysts are manual, dated annotations written by the Scout after a news check
# (state\catalysts.json: { "US.SYM": { "date": "yyyy-MM-dd", "type": "...", "note": "..." } }).
# A fresh record raises conviction; it is never required for a trade.
function Get-Catalysts {
    $p = Get-Path 'state\catalysts.json'
    if (-not (Test-Path $p)) { return [pscustomobject]@{} }
    $doc = Read-JsonFile $p
    if (-not $doc) { return [pscustomobject]@{} }
    $doc
}

function Get-Catalyst {
    param([string]$Symbol, [int]$ValidDays = 14)
    $all = Get-Catalysts
    $rec = Get-Prop $all $Symbol $null
    if (-not $rec) { return $null }
    $d = [string](Get-Prop $rec 'date' '')
    if (-not $d) { return $null }
    try { $age = ((Get-EtNow).Date - [datetime]::ParseExact($d, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)).TotalDays }
    catch { return $null }
    if ($age -lt 0 -or $age -gt $ValidDays) { return $null }
    $rec
}

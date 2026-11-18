. "$PSScriptRoot\..\engine\lib\Common.ps1"
. "$PSScriptRoot\..\engine\lib\Data.ps1"
. "$PSScriptRoot\..\engine\lib\Indicators.ps1"
$c = Get-Config
$u = Load-Universe
foreach ($m in @($u.members)) {
    $b = Load-Klines $m.symbol
    if (-not $b) { Write-Host ("{0,-10} NO BARS" -f $m.symbol); continue }
    $st = Get-Stage2 -Bars $b -Config $c
    Write-Host ("{0,-10} n={1,3} close={2,8:N2} sma50={3,8:N2} sma200={4,8:N2} rsi={5,5:N1} hi52={6,8:N2} lo52={7,8:N2} | a200={8,-5} rise={9,-5} stack={10,-5} offLow={11,-5} nearHigh={12,-5} rsiOk={13,-5} => {14}" -f `
            $m.symbol, $b.Count, $st.close, $st.sma50, $st.sma200, $st.rsi, $st.high52, $st.low52,
        $st.above200, $st.sma200Rising, $st.maStacked, $st.offLow, $st.nearHigh, $st.rsiOk, $st.pass)
}

# Build-Dashboard.ps1
# Generates a self-contained dashboard\index.html from the journals and state files.
# No CDN, no network: open the file directly.
#
#   powershell -File engine\Build-Dashboard.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/Data.ps1"

$state = Get-LatestPortfolioState
$proposals = Read-JsonFile (Get-Path 'state\proposals-latest.json')
$backtest = Read-JsonFile (Get-Path 'state\backtest-latest.json')
$stops = Read-JsonFile (Get-Path 'state\stops.json')
$decisions = @(Read-Jsonl (Get-Path 'journal\decisions.jsonl') | Select-Object -Last 120)
$orders = @(Read-Jsonl (Get-Path 'journal\orders.jsonl') | Select-Object -Last 120)
$scan = Read-JsonFile (Get-Path 'state\candidates-latest.json')
$market = Read-JsonFile (Get-Path 'state\market.json')

$payload = [pscustomobject]@{
    generated  = (Get-Date -Format 's')
    account    = (Get-Config).account
    competition = (Get-Config).competition
    state      = $state
    session    = (Get-SessionState)
    market     = $market
    scan       = $(if ($scan) { [pscustomobject]@{
            stage2    = (Get-Prop $scan 'stage2Count' 0)
            vcp       = (Get-Prop $scan 'vcpCount' 0)
            breakouts = (Get-Prop $scan 'breakoutCount' 0)
            setups    = (Get-Prop $scan 'setupCount' 0)
            jlawBreakouts = (Get-Prop $scan 'jlawBreakouts' 0)
            jlawSetups = (Get-Prop $scan 'jlawSetups' 0)
            universe  = (Get-Prop $scan 'universe' 0)
            version   = (Get-Prop $scan 'strategyVersion' '')
            generated = (Get-Prop $scan 'generated' '')
        } } else { $null })
    proposals  = $proposals
    backtest   = $backtest
    stops      = $stops
    decisions  = $decisions
    orders     = $orders
}
$json = $payload | ConvertTo-Json -Depth 20 -Compress
# The dashboard is meant to be shared; the account number is not. Scrub it from the whole
# payload, since state, proposals and order rows all carry it.
$acctId = [string](Get-Prop (Get-Config).account 'account_id' '')
if ($acctId) { $json = $json.Replace($acctId, 'challenge-account') }

$template = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>VCP Agent — Trade Journal &amp; Playbook</title>
<style>
:root{--bg:#0d1117;--panel:#161b22;--line:#30363d;--tx:#e6edf3;--mut:#8b949e;
--grn:#3fb950;--red:#f85149;--amb:#d29922;--blu:#58a6ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{padding:18px 24px;border-bottom:1px solid var(--line);display:flex;gap:16px;align-items:baseline;flex-wrap:wrap}
h1{font-size:18px;margin:0;font-weight:600}
.sub{color:var(--mut);font-size:12px}
main{padding:20px 24px;max-width:1280px;margin:0 auto}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:20px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px}
.k{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.06em}
.v{font-size:22px;font-weight:600;margin-top:6px;font-variant-numeric:tabular-nums}
.pos{color:var(--grn)}.neg{color:var(--red)}.amb{color:var(--amb)}
.tabs{display:flex;gap:6px;border-bottom:1px solid var(--line);margin-bottom:16px}
.tab{padding:9px 14px;cursor:pointer;color:var(--mut);border-bottom:2px solid transparent;font-size:13px}
.tab.on{color:var(--tx);border-bottom-color:var(--blu)}
.panel{display:none}.panel.on{display:block}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
th{text-align:left;color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.05em;
padding:8px 10px;border-bottom:1px solid var(--line);font-weight:500}
td{padding:8px 10px;border-bottom:1px solid #21262d;font-size:13px}
tr:hover td{background:#1c2128}
.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:600}
.ok{background:rgba(63,185,80,.15);color:var(--grn)}
.no{background:rgba(248,81,73,.15);color:var(--red)}
.n{color:var(--mut)}
.empty{color:var(--mut);padding:28px;text-align:center;border:1px dashed var(--line);border-radius:8px}
.small{font-size:12px;color:var(--mut)}
.rules{display:flex;flex-wrap:wrap;gap:6px;max-width:520px}
.tag{background:#21262d;border:1px solid var(--line);border-radius:6px;padding:2px 7px;font-size:11px;color:var(--red)}
h3{font-size:14px;margin:22px 0 10px;font-weight:600}
.bar{height:6px;background:#21262d;border-radius:3px;overflow:hidden;width:90px;display:inline-block;vertical-align:middle}
.bar>i{display:block;height:100%;background:var(--blu)}
</style>
</head>
<body>
<header>
  <h1>VCP Agent — Trade Journal &amp; Playbook</h1>
  <span class="sub" id="hdr"></span>
</header>
<main>
  <div class="cards" id="cards"></div>
  <div class="tabs">
    <div class="tab on" data-p="journal">Trade Journal</div>
    <div class="tab" data-p="playbook">Trend Following Playbook</div>
    <div class="tab" data-p="research">Research &amp; Backtest</div>
  </div>

  <div class="panel on" id="p-journal">
    <h3>Decision log (approved and rejected, with the rule that blocked it)</h3>
    <div id="decisions"></div>
    <h3>Order attempts</h3>
    <div id="orders"></div>
  </div>

  <div class="panel" id="p-playbook">
    <h3>Positions and protective stops</h3>
    <div id="positions"></div>
    <h3>Open orders</h3>
    <div id="openorders"></div>
    <h3>Current proposals (ranked)</h3>
    <div id="ranked"></div>
  </div>

  <div class="panel" id="p-research">
    <h3>Backtest — walk-forward, costs included</h3>
    <div id="bt"></div>
    <h3>Universe scan</h3>
    <div id="scan"></div>
  </div>
</main>
<script id="data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('data').textContent);
const $ = s => document.querySelector(s);
const money = v => (v==null||isNaN(v)) ? '—' : '$' + Number(v).toLocaleString('en-US',{maximumFractionDigits:0});
const money2 = v => (v==null||isNaN(v)) ? '—' : '$' + Number(v).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});
const pct = v => (v==null||isNaN(v)) ? '—' : (Number(v)*100).toFixed(1) + '%';
const esc = s => String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

$('#hdr').textContent = 'Generated ' + D.generated + ' · ' + (D.account?D.account.account_title:'—') +
  ' · flatten ' + (D.competition?D.competition.flatten_deadline:'—');

const st = D.state || {};
const eq = st.equity || 0, base = (D.account && D.account.equity_baseline) || 100000;
const pnl = eq - base;
const mk = D.market || null;
const cards = [
  ['Equity', money(eq)],
  ['Cash', money(st.cash)],
  ['Day P/L', money2(pnl), pnl>=0?'pos':'neg'],
  ['Open positions', (st.positions||[]).length],
  ['Orders today', (st.today?st.today.executedOrders:0)],
  ['SPY regime', mk ? (mk.ok ? (mk.bearish?'CORRECTION':'TREND') : 'UNKNOWN') : '—',
   mk && mk.ok ? (mk.bearish?'neg':'pos') : 'amb',
   mk && mk.ok ? (money2(mk.close)+' vs '+mk.smaPeriod+'DMA '+money2(mk.sma)+(mk.falling?' ↓':'')) : 'no regime file'],
  ['Session', (D.session?D.session.session:(st.session?st.session.session:'—'))]
];
$('#cards').innerHTML = cards.map(c =>
  '<div class="card"><div class="k">'+c[0]+'</div><div class="v '+(c[2]||'')+'">'+c[1]+'</div>'+
  (c[3]?'<div class="small">'+esc(c[3])+'</div>':'')+'</div>').join('');

function table(rows, cols, empty){
  if(!rows || !rows.length) return '<div class="empty">'+empty+'</div>';
  return '<table><thead><tr>' + cols.map(c=>'<th>'+c.h+'</th>').join('') + '</tr></thead><tbody>' +
    rows.map(r=>'<tr>' + cols.map(c=>'<td>'+c.f(r)+'</td>').join('') + '</tr>').join('') +
    '</tbody></table>';
}

// ---- journal ----
const dec = (D.decisions||[]).slice().reverse();
$('#decisions').innerHTML = table(dec, [
  {h:'Time', f:r=>'<span class="n">'+esc((r.ts||'').replace('T',' ').slice(0,19))+'</span>'},
  {h:'Symbol', f:r=>'<b>'+esc(r.symbol)+'</b>'},
  {h:'Side', f:r=>esc(r.side)},
  {h:'Qty', f:r=>esc(r.qty)},
  {h:'Price', f:r=>money2(r.price)},
  {h:'Conviction', f:r=>r.conviction==null?'—':'<span class="bar"><i style="width:'+Math.round(r.conviction*100)+'%"></i></span> '+Number(r.conviction).toFixed(2)},
  {h:'Verdict', f:r=>r.approved?'<span class="pill ok">APPROVED</span>':'<span class="pill no">REJECTED</span>'},
  {h:'Why', f:r=> (r.approved? '<span class="small">'+esc(r.thesis||'')+'</span>'
        : '<div class="rules">'+(r.violations||[]).map(v=>'<span class="tag" title="'+esc(v.msg)+'">'+esc(v.rule)+': '+esc(v.msg)+'</span>').join('')+'</div>')}
], 'No decisions yet.');

const ords = (D.orders||[]).slice().reverse();
$('#orders').innerHTML = table(ords, [
  {h:'Time', f:r=>'<span class="n">'+esc((r.ts||'').replace('T',' ').slice(0,19))+'</span>'},
  {h:'Symbol', f:r=>'<b>'+esc(r.symbol)+'</b>'},
  {h:'Side', f:r=>esc(r.side)},
  {h:'Qty', f:r=>esc(r.qty)},
  {h:'Price', f:r=>r.price==='market'?'market':money2(r.price)},
  {h:'Order ID', f:r=>esc(r.orderId||'')},
  {h:'Status', f:r=> r.error? '<span class="pill no">ERROR</span> <span class="small">'+esc(r.error)+'</span>'
        : (r.submitted? '<span class="pill ok">SUBMITTED</span>' : '<span class="n">dry-run</span>')}
], 'No orders yet.');

// ---- playbook ----
const pos = (st.positions||[]);
$('#positions').innerHTML = table(pos, [
  {h:'Symbol', f:r=>'<b>'+esc(r.symbol)+'</b>'},
  {h:'Qty', f:r=>esc(r.qty)},
  {h:'Avg cost', f:r=>money2(r.avgCost)},
  {h:'Last', f:r=>money2(r.lastPrice)},
  {h:'Market value', f:r=>money(r.marketValue)},
  {h:'Unrealised', f:r=>'<span class="'+(r.unrealizedPl>=0?'pos':'neg')+'">'+money2(r.unrealizedPl)+'</span>'},
  {h:'Stop', f:r=>{const s=D.stops&&D.stops[r.symbol]; return s? money2(s.stop)+(s.breakeven?' <span class="small amb">BE</span>':'')+(s.trimmed?' <span class="small">· trimmed</span>':''):'<span class="pill no">none</span>';}},
  {h:'Pivot', f:r=>{const s=D.stops&&D.stops[r.symbol]; return s?money2(s.pivot):'—';}},
  {h:'Trim at', f:r=>{const s=D.stops&&D.stops[r.symbol]; return s&&s.atr?money2(s.entry + 3*s.atr):'—';}}
], 'Flat — no open positions.');

$('#openorders').innerHTML = table((st.openOrders||[]), [
  {h:'Symbol', f:r=>'<b>'+esc(r.symbol)+'</b>'},
  {h:'Side', f:r=>esc(r.side)},
  {h:'Qty', f:r=>esc(r.qty)},
  {h:'Limit', f:r=>money2(r.price)},
  {h:'Type', f:r=>esc(r.type)},
  {h:'Order ID', f:r=>esc(r.orderId)}
], 'No open orders.');

const ranked = ((D.proposals&&D.proposals.ranked)||[]);
$('#ranked').innerHTML = table(ranked, [
  {h:'Symbol', f:r=>'<b>'+esc(r.symbol)+'</b> <span class="small">'+esc(r.name||'')+'</span>'},
  {h:'Sector', f:r=>esc(r.sector||'—')+(r.leading?' <span class="pill ok">LEAD</span>':'')},
  {h:'Pivot', f:r=>money2(r.pivot)},
  {h:'Limit', f:r=>money2(r.entry)},
  {h:'Stop', f:r=>money2(r.stop)},
  {h:'Qty', f:r=>esc(r.qty)},
  {h:'Conviction', f:r=>r.conviction==null?'—':'<span class="bar"><i style="width:'+Math.round(r.conviction*100)+'%"></i></span> '+Number(r.conviction).toFixed(2)},
  {h:'Contractions', f:r=>(r.depths||[]).map(d=>pct(d)).join(' → ')},
  {h:'Vol dry-up', f:r=>r.volDryRatio==null?'—':Number(r.volDryRatio).toFixed(2)+'×'},
  {h:'J Law', f:r=>(r.jlawMode==='fallback-vcp'?'<span class="tag">FALLBACK VCP</span> ':'')+
      (r.edges!=null?r.edges+' edges':'—')+
      (r.edgeList&&r.edgeList.length?' <span class="small">['+esc(r.edgeList.join('/'))+']</span>':'')+
      (r.heavyVolDays!=null?' · '+r.heavyVolDays+' heavy':'')+
      (r.catalyst?' <span class="pill ok">'+esc(r.catalyst)+'</span>':'')}
], 'No proposals in this cycle.');

// ---- research ----
const bt = D.backtest;
if(!bt){ $('#bt').innerHTML = '<div class="empty">No backtest yet. Run engine\\Backtest.ps1.</div>'; }
else {
  const rows = [
    {m:'All', s:bt.all}, {m:'In-sample', s:bt.inSample}, {m:'Out-of-sample', s:bt.outOfSample}
  ];
  $('#bt').innerHTML = table(rows, [
    {h:'Segment', f:r=>'<b>'+r.m+'</b>'},
    {h:'Trades', f:r=>r.s.trades},
    {h:'Win rate', f:r=>pct(r.s.winRate)},
    {h:'Expectancy', f:r=>money2(r.s.expectancy)},
    {h:'Profit factor', f:r=>r.s.profitFactor==null?'—':Number(r.s.profitFactor).toFixed(2)},
    {h:'Return', f:r=>'<span class="'+(r.s.totalReturn>=0?'pos':'neg')+'">'+pct(r.s.totalReturn)+'</span>'},
    {h:'Max DD', f:r=>'<span class="neg">'+pct(r.s.maxDrawdown)+'</span>'},
    {h:'Sharpe', f:r=>r.s.sharpe==null?'—':Number(r.s.sharpe).toFixed(2)},
    {h:'Sortino', f:r=>r.s.sortino==null?'—':Number(r.s.sortino).toFixed(2)},
    {h:'Avg hold', f:r=>Number(r.s.avgHoldDays).toFixed(1)+'d'}
  ], '');
  $('#bt').innerHTML += '<p class="small">Universe '+bt.universe+' names · '+bt.window.sessions+
    ' sessions '+bt.window.start+'–'+bt.window.end+' · costs '+(bt.costs.slippage*10000).toFixed(0)+
    'bp slippage +'+(bt.costs.halfSpread*10000).toFixed(0)+'bp half-spread · version '+bt.strategyVersion+
    (bt.benchmark? ' · SPY buy &amp; hold '+pct(bt.benchmark.totalReturn) : '')+'</p>';
  if(bt.funnel){
    const f=bt.funnel;
    $('#bt').innerHTML += '<p class="small">Funnel: stage2 '+f.stage2+' → VCP '+f.vcp+' → breakout '+f.breakout+
      ' → volume '+f.volumeOk+' → J Law '+f.jlaw+' → fills '+f.fills+
      ' · trims '+f.trims+' · days blocked by R13 '+f.regimeBlockedDays+'</p>';
    if(f.jlawSub){
      const s=f.jlawSub;
      $('#bt').innerHTML += '<p class="small">J Law sub-funnel (first failing stage): '+s.dollarVolumeFail+
        ' under $100m/day · '+s.heavyVolumeFail+' with &lt;2 heavy days · '+s.edgesFail+
        ' with &lt;2 edges · '+s.rsFail+' lagging SPY</p>';
    }
  }
}
const sc = D.scan;
$('#scan').innerHTML = sc? table([sc], [
  {h:'Generated', f:r=>esc(r.generated)},
  {h:'Version', f:r=>esc(r.version||'—')},
  {h:'Universe', f:r=>r.universe},
  {h:'Stage 2', f:r=>r.stage2},
  {h:'With VCP', f:r=>r.vcp},
  {h:'Breakouts', f:r=>r.breakouts},
  {h:'Setups', f:r=>r.setups},
  {h:'J Law breakouts', f:r=>r.jlawBreakouts},
  {h:'J Law setups', f:r=>r.jlawSetups}
], '') : '<div class="empty">No scan yet.</div>';

document.querySelectorAll('.tab').forEach(t=>t.onclick=()=>{
  document.querySelectorAll('.tab').forEach(x=>x.classList.remove('on'));
  document.querySelectorAll('.panel').forEach(x=>x.classList.remove('on'));
  t.classList.add('on'); $('#p-'+t.dataset.p).classList.add('on');
});
</script>
</body>
</html>
'@

$html = $template.Replace('__DATA__', $json)
$out = Get-Path 'dashboard\index.html'
Ensure-Dir (Split-Path $out -Parent) | Out-Null
Set-Content -Path $out -Value $html -Encoding UTF8
Write-Output "DASHBOARD=$out"

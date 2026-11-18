@echo off
rem RUN-ENGINE.cmd - thin launcher for the trading engine.
rem   RUN-ENGINE            dry-run cycle (no orders)
rem   RUN-ENGINE execute    cycle that may place approved orders
rem   RUN-ENGINE stops      one stop-watch pass, market sells on breach
rem   RUN-ENGINE watch      stop watch loop (60s) until 20:00 ET (after-hours included)
rem   RUN-ENGINE reconcile  pull broker truth only
rem   RUN-ENGINE scan       rescan the universe for VCP setups
rem   RUN-ENGINE dashboard  rebuild dashboard\index.html
rem   RUN-ENGINE backtest   walk-forward backtest
rem   RUN-ENGINE awake      hold the machine out of sleep for the session
rem   RUN-ENGINE power      power source and sleep timeouts
setlocal
set "ENGINE=%~dp0engine"
set "PS=powershell.exe -NoProfile -ExecutionPolicy Bypass -File"
set "ARG=%~1"
if "%ARG%"==""             ( %PS% "%ENGINE%\Invoke-Cycle.ps1"            & goto :eof )
if /i "%ARG%"=="execute"   ( %PS% "%ENGINE%\Invoke-Cycle.ps1" -Execute   & goto :eof )
if /i "%ARG%"=="stops"     ( %PS% "%ENGINE%\6-StopWatch.ps1"             & goto :eof )
if /i "%ARG%"=="watch"     ( %PS% "%ENGINE%\6-StopWatch.ps1" -Loop       & goto :eof )
if /i "%ARG%"=="reconcile" ( %PS% "%ENGINE%\3-Reconcile.ps1"             & goto :eof )
if /i "%ARG%"=="scan"      ( %PS% "%ENGINE%\2-Scan-Vcp.ps1"              & goto :eof )
if /i "%ARG%"=="dashboard" ( %PS% "%ENGINE%\Build-Dashboard.ps1"         & goto :eof )
if /i "%ARG%"=="backtest"  ( %PS% "%ENGINE%\Backtest.ps1"                & goto :eof )
if /i "%ARG%"=="awake"     ( %PS% "%ENGINE%\8-KeepAwake.ps1" -Hold      & goto :eof )
if /i "%ARG%"=="power"     ( %PS% "%ENGINE%\8-KeepAwake.ps1" -Status    & goto :eof )
if /i "%ARG%"=="poweroff"  ( %PS% "%ENGINE%\10-Shutdown.ps1"            & goto :eof )
echo Unknown command: %ARG%
echo Try: execute ^| stops ^| watch ^| reconcile ^| scan ^| dashboard ^| backtest ^| awake ^| power ^| poweroff

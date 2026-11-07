@echo off
rem Cache Clean - CLI launcher
setlocal
set "PS=powershell.exe"
where pwsh >nul 2>nul && set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cache-clean.ps1" %*
set "RC=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %RC%

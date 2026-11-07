@echo off
rem Cache Clean - GUI launcher (double-click me)
start "" /b powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0cache-clean-gui.ps1"
exit /b 0

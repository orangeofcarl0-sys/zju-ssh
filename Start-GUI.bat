@echo off
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0zju-ssh-gui.ps1"
exit /b 0

@echo off
start "" /min powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Start-IPCM-Logging.ps1"
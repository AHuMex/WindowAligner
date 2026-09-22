@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Align-Window.ps1"
if errorlevel 1 pause

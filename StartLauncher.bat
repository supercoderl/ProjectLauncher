@echo off
rem ---------------------------------------------------------------------------
rem  C# Project Launcher
rem  Starts ProjectLauncher.ps1 with PowerShell 7 (pwsh) when installed,
rem  otherwise with the built-in Windows PowerShell 5.1.
rem
rem  Usage:  StartLauncher.bat                 (uses config.json)
rem          StartLauncher.bat "F:\Workspace"  (scan another folder)
rem ---------------------------------------------------------------------------
setlocal
set "LAUNCHER=%~dp0ProjectLauncher.ps1"

where pwsh >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" %*
) else (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" %*
)

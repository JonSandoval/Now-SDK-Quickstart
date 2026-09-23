@echo off
setlocal
title ServiceNow SDK Setup

rem Runs the setup script for the current user only. No admin rights needed.
rem Any arguments are passed through, e.g.:
rem   Setup-ServiceNowSDK.cmd -InstanceUrl https://acme.service-now.com -Alias acme -NoGui

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Setup-ServiceNowSDK.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo Setup did not complete ^(exit code %RC%^).
    echo Details are in: %LOCALAPPDATA%\ServiceNowSdkSetup\setup.log
    echo.
    echo If PowerShell refused to run the script at all, your organization may enforce
    echo a script policy. Ask IT to allow Setup-ServiceNowSDK.ps1 or to install the
    echo ServiceNow SDK for you.
    echo.
    pause
)
exit /b %RC%

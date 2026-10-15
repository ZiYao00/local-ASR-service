@echo off
setlocal EnableExtensions
chcp 65001 >nul

if "%~1"=="" goto menu
if /i "%~1"=="start" goto command
if /i "%~1"=="stop" goto command
if /i "%~1"=="restart" goto command
if /i "%~1"=="status" goto command
if /i "%~1"=="open" goto command
if /i "%~1"=="start-open" goto command
if /i "%~1"=="logs" goto command
echo Usage: service.bat [start^|stop^|restart^|status^|open^|start-open^|logs]
exit /b 2

:command
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\service.ps1" -Command "%~1"
exit /b %ERRORLEVEL%

:menu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\service.ps1" -Command menu
exit /b %ERRORLEVEL%

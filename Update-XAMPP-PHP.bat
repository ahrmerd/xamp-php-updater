@echo off
setlocal

net session >nul 2>&1
if %errorLevel% == 0 goto :run

echo Administrator privileges are required. Requesting elevation...
powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-xampp-php.ps1"
echo.
pause

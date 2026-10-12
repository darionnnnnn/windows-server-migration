@echo off
setlocal
cd /d "%~dp0"
set "WSM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "WSM_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%WSM_POWERSHELL%" (
  echo Windows PowerShell 5.1 x64 is required. Ask your administrator for help.
  pause
  exit /b 1
)
echo Starting the migration tool. Keep this window open.
"%WSM_POWERSHELL%" -NoProfile -File "%~dp0Start-ServerMigration.ps1"
set "WSM_EXIT=%ERRORLEVEL%"
if not "%WSM_EXIT%"=="0" (
  echo The tool stopped. Keep the message above for your administrator.
  echo If access is denied, right-click this launcher and select Run as administrator.
  echo If script execution is blocked, ask your administrator to approve this tool.
  pause
)
exit /b %WSM_EXIT%

@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem Starts QuickLaunch. Needs PowerShell 7 (pwsh.exe); offers to install it when missing.

set "HERE=%~dp0"
set "TARGET=%HERE%quicklaunch.ps1"
set "PWSH="

if not exist "%TARGET%" (
    echo quicklaunch.ps1 was not found next to this file:
    echo   %TARGET%
    pause
    exit /b 1
)

call :findpwsh
if not defined PWSH (
    echo PowerShell 7 ^(pwsh.exe^) was not found.
    echo QuickLaunch cannot run without it.
    echo.
    choice /c YN /t 30 /d N /m "Download and install PowerShell 7 now"
    if errorlevel 2 goto :nopwsh
    call :installpwsh
    call :findpwsh
    if not defined PWSH goto :nopwsh
    echo PowerShell 7 installed: !PWSH!
)

rem the .vbs shim starts it with no console window at all
if exist "%HERE%quicklaunch.vbs" (
    start "" wscript.exe "%HERE%quicklaunch.vbs"
) else (
    start "" "%PWSH%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%TARGET%"
)
exit /b 0

:findpwsh
for %%P in (pwsh.exe) do if not defined PWSH if not "%%~$PATH:P"=="" set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
exit /b 0

:installpwsh
where winget >nul 2>&1
if not errorlevel 1 (
    echo Installing through winget...
    winget install --id Microsoft.PowerShell --exact --source winget ^
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    if not errorlevel 1 exit /b 0
    echo winget did not succeed, falling back to the MSI download.
)

rem fallback: fetch the current MSI from the official GitHub release and install it silently
set "MSI=%TEMP%\PowerShell-7-win-x64.msi"
echo Downloading the PowerShell 7 installer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;" ^
  "$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {'arm64'} else {'x64'};" ^
  "$r = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{'User-Agent'='quicklaunch'};" ^
  "$a = $r.assets | Where-Object { $_.name -like ('*win-' + $arch + '.msi') } | Select-Object -First 1;" ^
  "if (-not $a) { throw 'no MSI asset found in the latest release' };" ^
  "Invoke-WebRequest $a.browser_download_url -OutFile '%MSI%' -UseBasicParsing"
if errorlevel 1 (
    echo The installer could not be downloaded.
    exit /b 1
)

echo Installing... a UAC prompt will appear.
rem elevate msiexec; ADD_PATH puts pwsh.exe on PATH for the next start
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = Start-Process msiexec.exe -ArgumentList '/i','\"%MSI%\"','/qn','/norestart','ADD_PATH=1' -Verb RunAs -Wait -PassThru;" ^
  "exit $p.ExitCode"
if errorlevel 1 (
    echo The installation failed.
    exit /b 1
)
del "%MSI%" >nul 2>&1
exit /b 0

:nopwsh
echo.
echo Install PowerShell 7 manually, then run this file again:
echo   winget install Microsoft.PowerShell
echo   https://github.com/PowerShell/PowerShell/releases/latest
echo.
pause
exit /b 1

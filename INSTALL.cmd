@echo off
REM ---------------------------------------------------------------------------
REM  OpenCode 2.x setup - double-click this file, or run it from a terminal.
REM  Keeps the window open so you can read the result.
REM ---------------------------------------------------------------------------
setlocal

set "HERE=%~dp0"
set "PS1=%HERE%install.ps1"

if not exist "%PS1%" (
    echo [FAIL] install.ps1 not found next to this file.
    echo        Extract the whole zip before running it.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo Setup finished. Open the "OpenCode" icon on your desktop.
) else (
    echo Setup did not finish ^(exit code %RC%^). See the error above.
)
echo.
pause
exit /b %RC%
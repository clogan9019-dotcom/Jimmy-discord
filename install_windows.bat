@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1" %*
set "INSTALL_EXIT_CODE=%ERRORLEVEL%"

echo.
if "%INSTALL_EXIT_CODE%"=="0" (
    echo Windows GGUF builder finished successfully.
) else (
    echo Windows GGUF builder exited with code %INSTALL_EXIT_CODE%.
)
echo.
pause
exit /b %INSTALL_EXIT_CODE%

@echo off
setlocal
cd /d "%~dp0"
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows_tinydolphin.ps1" %*
set "INSTALL_EXIT_CODE=%ERRORLEVEL%"
echo.
if "%INSTALL_EXIT_CODE%"=="0" (
    echo Windows TinyDolphin setup finished successfully.
) else (
    echo Windows TinyDolphin setup exited with code %INSTALL_EXIT_CODE%.
)
echo.
pause
exit /b %INSTALL_EXIT_CODE%

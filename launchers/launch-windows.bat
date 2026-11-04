@echo off
REM Shared Windows launcher. The per-tool .bat files set AITRANS_MODE and call this file.
setlocal EnableExtensions
cd /d "%~dp0.."
title AItrans
chcp 65001 >nul 2>&1
set "PYTHONIOENCODING=utf-8"

if not defined AITRANS_MODE (
    echo Error: unknown launcher mode. Run one of the tool .bat files in this folder.
    pause
    exit /b 1
)

set "PYTHON_CMD="
py -3 -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>&1
if not errorlevel 1 set "PYTHON_CMD=py -3"
if not defined PYTHON_CMD (
    python -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>&1
    if not errorlevel 1 set "PYTHON_CMD=python"
)
if not defined PYTHON_CMD (
    python3 -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>&1
    if not errorlevel 1 set "PYTHON_CMD=python3"
)

if not defined PYTHON_CMD (
    echo Python 3.10 or newer was not found.
    echo Install it from https://www.python.org/downloads/windows/ and try again.
    echo.
    pause
    exit /b 1
)

%PYTHON_CMD% -B "%~dp0launch-windows.py" --mode %AITRANS_MODE% %*
set "AITRANS_EXIT=%ERRORLEVEL%"

if not "%AITRANS_EXIT%"=="0" (
    echo.
    echo Something went wrong. See the messages above.
)

if not "%AITRANS_NO_PAUSE%"=="1" pause
exit /b %AITRANS_EXIT%

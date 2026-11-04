@echo off
setlocal
set "AITRANS_MODE=provider"
call "%~dp0launch-windows.bat" %*
exit /b %ERRORLEVEL%

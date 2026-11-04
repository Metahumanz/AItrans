@echo off
setlocal
set "AITRANS_MODE=provider"
call "%~dp0..\launchers\launch-windows.bat" %*
exit /b %ERRORLEVEL%

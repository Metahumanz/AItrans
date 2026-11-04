@echo off
setlocal
set "AITRANS_MODE=aitrans"
call "%~dp0launchers\launch-windows.bat" %*
exit /b %ERRORLEVEL%

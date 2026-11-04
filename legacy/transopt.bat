@echo off
setlocal
set "AITRANS_MODE=transopt"
call "%~dp0..\launchers\launch-windows.bat" %*
exit /b %ERRORLEVEL%

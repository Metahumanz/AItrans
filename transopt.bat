@echo off
setlocal
set "AITRANS_MODE=transopt"
call "%~dp0launch-windows.bat" %*
exit /b %ERRORLEVEL%

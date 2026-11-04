@echo off
setlocal
set "AITRANS_MODE=aitrans"
call "%~dp0launch-windows.bat" %*
exit /b %ERRORLEVEL%

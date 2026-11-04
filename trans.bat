@echo off
setlocal
set "AITRANS_MODE=trans"
call "%~dp0launch-windows.bat" %*
exit /b %ERRORLEVEL%

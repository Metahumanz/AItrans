@echo off
setlocal
set "AITRANS_MODE=transoptdeepseek"
call "%~dp0launch-windows.bat" %*
exit /b %ERRORLEVEL%

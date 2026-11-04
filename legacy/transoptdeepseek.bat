@echo off
setlocal
set "AITRANS_MODE=transoptdeepseek"
call "%~dp0..\launchers\launch-windows.bat" %*
exit /b %ERRORLEVEL%

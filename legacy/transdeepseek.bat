@echo off
setlocal
set "AITRANS_MODE=transdeepseek"
call "%~dp0..\launchers\launch-windows.bat" %*
exit /b %ERRORLEVEL%

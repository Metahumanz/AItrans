@echo off
setlocal
set "AITRANS_MODE=transdeepseek"
call "%~dp0launch-windows.bat" %*
exit /b %ERRORLEVEL%

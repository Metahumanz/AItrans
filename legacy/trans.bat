@echo off
setlocal
set "AITRANS_MODE=trans"
call "%~dp0..\launchers\launch-windows.bat" %*
exit /b %ERRORLEVEL%

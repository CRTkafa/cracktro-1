@echo off
setlocal
cd /d "%~dp0"
rem Always rebuild: an existing video renderer may embed stale shaders.
call buildgfx.bat video || exit /b 1
python tools\export_video.py
exit /b %errorlevel%

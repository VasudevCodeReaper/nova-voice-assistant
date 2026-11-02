@echo off
setlocal
set "NOVA_ROOT=%~dp0"
python "%NOVA_ROOT%NovaWhisper.py" --config "%NOVA_ROOT%nova.config.json"
if errorlevel 1 pause
endlocal

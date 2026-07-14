@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-JiraTree.ps1" %*

echo.
pause

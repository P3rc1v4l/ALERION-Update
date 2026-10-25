@echo off
rem Double-click to install Update Center (asks for administrator rights once).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"

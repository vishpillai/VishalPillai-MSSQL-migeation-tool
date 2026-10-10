@echo off
setlocal
set "APPROOT=%~dp0"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%APPROOT%Start-PortableDbMigrationWeb.ps1"

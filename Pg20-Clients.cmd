@echo off
rem Pg20 Info : ouvre la page clients dans votre navigateur (import USB, validation, connexion RustDesk).
rem Option : Pg20-Clients.cmd -Console   pour l'ancien menu en mode texte.
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0Pg20-Clients.ps1" %*
if errorlevel 1 pause

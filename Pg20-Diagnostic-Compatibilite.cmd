@echo off
title Pg20 Info - diagnostic de compatibilite
echo Diagnostic en lecture seule : rien n'est installe ni modifie.
echo Pour un rapport complet : clic droit sur ce fichier, puis Executer en tant qu'administrateur.
echo.
set /p PG20_SERVEUR=Adresse du serveur a tester (exemple 203.0.113.10:21120, vide pour passer) : 
if defined PG20_SERVEUR goto avec
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Pg20-Diagnostic-Compatibilite.ps1" -Save
goto fin
:avec
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Pg20-Diagnostic-Compatibilite.ps1" -Save -Server %PG20_SERVEUR%
:fin
echo.
pause

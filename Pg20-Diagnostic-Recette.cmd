@echo off
title Pg20 Info - rapport de recette
echo Rapport en lecture seule : rien n'est installe ni modifie (sauf le fichier Recette-AAAAMMJJ-HHMM.txt ecrit a cote de ce fichier).
echo Pour un rapport complet : clic droit sur ce fichier, puis Executer en tant qu'administrateur.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Pg20-Diagnostic-Recette.ps1"
echo.
pause

@echo off
title Pg20 Info - mesure des ports de RustDesk
echo Mesure en lecture seule : rien n'est installe ni modifie (sauf le fichier Ports-AAAAMMJJ-HHMM.txt ecrit a cote de ce fichier).
echo RustDesk doit etre installe ET lance sur ce poste. Pour un rapport complet : clic droit sur ce fichier, puis Executer en tant qu'administrateur.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Pg20-Diagnostic-Ports.ps1"
echo.
pause

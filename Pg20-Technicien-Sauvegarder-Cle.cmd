@echo off
title Pg20 Info - sauvegarde de la cle privee du technicien
echo ============================================================================
echo  SAUVEGARDE DE LA CLE PRIVEE (a faire UNE fois, puis apres tout changement)
echo ============================================================================
echo  Etape 1 : la cle est copiee dans le presse-papiers (elle ne s'affiche pas).
echo            Collez-la dans une NOTE SECURISEE de votre gestionnaire de mots de passe.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0Pg20-Technicien-Configurer.ps1" -ExportBackup -Clipboard
echo.
echo ============================================================================
echo  Etape 2 : VERIFICATION. Dans votre gestionnaire, COPIEZ la note (Ctrl+C),
echo            puis appuyez sur une touche ici.
echo ============================================================================
pause >nul
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0Pg20-Technicien-Configurer.ps1" -VerifyBackup -Clipboard
echo.
pause

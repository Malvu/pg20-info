# Nouveautés Pg20 Info

## 2026-10-07 | Client léger, ports protégés, déploiement par script, nouveaux noms de scripts

- Client léger : dépannage sans rien installer (un seul exe, RustDesk tourne depuis un dossier temporaire, tout est effacé à la fin).
- Installation avec fenêtres (progression, résumé, erreurs), marque Pg20 Info, éjection automatique de la clé USB après validation.
- Réinstallation propre d'un poste déjà connu du serveur, empreinte non réversible du matériel pour reconnaître le même ordinateur.
- Protection des ports : deux réglages RustDesk et deux règles du pare-feu Windows réduisent l'exposition réseau des postes.
- Déploiement silencieux par script (stratégie de groupe, outil de gestion à distance) : `Pg20-Deploiement-Poste.ps1`.
- Fabrication des exes par client ou générique : `Pg20-Exe-Fabriquer.ps1` (réglages locaux dans `build.config.json`, jamais publié).
- Carnet du technicien : anciens postes remplacés détectés, masqués puis purgés, restauration depuis une archive chiffrée du serveur.
- Serveur : archive chiffrée des fiches (`install-archive.sh`), ordres de désinstallation vérifiés toutes les 3 minutes.
- Home Assistant : la notification se ferme quand la fiche est traitée ailleurs, bouton « Valider » affiché seulement s'il y a une fiche en attente.
- Outils de diagnostic en lecture seule : compatibilité, recette, ports.
- Les scripts ont de nouveaux noms (`Pg20-Domaine-Action`) : par exemple `Build-Installer.ps1` devient `Pg20-Exe-Compiler.ps1` et `Setup-Technician.ps1` devient `Pg20-Technicien-Configurer.ps1`.
- Limites : exes non signés (SmartScreen, antivirus), conditions d'installation jamais relues par un juriste, déploiement par stratégie de groupe jamais essayé sur un vrai domaine.

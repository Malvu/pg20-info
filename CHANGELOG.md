# Nouveautés Info Pg20

## 2026-10-23 | État en ligne, dernière connexion, construction n°8 et serveur durci

- Nom affiché : le projet s'appelle désormais « Info Pg20 » partout à l'écran (les noms techniques des scripts, dossiers et services ne changent pas).
- État « en ligne » des postes dans « Se connecter » et dans la page des clients (● en ligne / ○ hors ligne), demandé directement au serveur RustDesk, en lecture seule, depuis le réseau local ou le VPN.
- Dernière connexion des postes : un petit service du serveur (`peers-presence.py`, toutes les 15 secondes) note quand chaque poste a été vu en ligne, servi sur `GET /presence` avec le même jeton que la liste des postes ; la carte d'un client hors ligne affiche « première connexion le … · a été connecté le … ».
- Fenêtre d'acceptation des conditions : le texte doit être lu jusqu'à la fin et l'adresse e-mail du client est obligatoire ; la preuve d'acceptation enregistre les deux.
- Installation (construction n°8) : le fichier de secours du mot de passe n'est plus lisible que par les administrateurs, le système et le compte courant ; une installation de RustDesk déjà présente n'est plus prise pour une installation en cours ; la fenêtre de l'Explorateur se ferme dès le début.
- Relance sans changement d'identité : le mot de passe existant est conservé, la fiche du carnet reste juste ; une réinstallation propre donne toujours un nouvel identifiant et un nouveau mot de passe.
- Carnet du technicien : purge automatique des postes masqués et résiliation d'un client selon les délais des conditions, liste de postes ignorés, nettoyage des postes inconnus du serveur (jamais du carnet).
- Serveur, receveur des fiches : au plus 4 connexions simultanées par adresse, en-têtes HTTP limités à 16 Ko, contrôle de présence séparé du quota des fiches.
- Serveur, liste des postes : le flux peut désormais être chiffré en réutilisant le certificat du receveur ; sans certificat, il fonctionne comme avant.
- Diagnostic de recette : nouvelle mesure de la consommation de RustDesk au repos (mémoire, processeur, disque, réseau) avec un verdict « petite configuration ».
- Tutos FR et EN : limites connues mises à jour (état en ligne, première et dernière connexion des postes).
- Limite rappelée : les exes ne sont pas signés ; certains antivirus (dont ESET) peuvent bloquer l'exe en ligne, l'exe hors ligne est à préférer.

## 2026-10-08 | Tutos corrigés : tâche de maintenance toutes les 3 minutes

- Tutos FR et EN : l'intervalle de la tâche de maintenance est de 3 minutes, et non 30 (désinstallation automatique, schéma d'architecture, déclencheurs de la tâche, limites).
- Limite du receveur précisée : 60 demandes d'ordre par tranche de 10 minutes et par adresse publique, soit environ 18 postes par site à cet intervalle.
- Les tutos utilisent partout les nouveaux noms de scripts (`Pg20-Domaine-Action`).

## 2026-10-07 | Client léger, ports protégés, déploiement par script, nouveaux noms de scripts

- Client léger : dépannage sans rien installer (un seul exe, RustDesk tourne depuis un dossier temporaire, tout est effacé à la fin).
- Installation avec fenêtres (progression, résumé, erreurs), marque Info Pg20, éjection automatique de la clé USB après validation.
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

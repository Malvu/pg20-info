# Kit Pg20 Info (version assainie)

> English translation: [`LISEZMOI-KIT.en.md`](LISEZMOI-KIT.en.md). Le français fait foi.

Scripts du montage décrit dans `TUTO-Pg20-Info.html` (à lire en premier, surtout la section « Risques et garde-fous »).
Kit assaini le 2026-10-03, mis à jour le 2026-10-04 (conditions, preuve d'acceptation, désinstallation, tâche de maintenance) : les adresses, clés, empreintes, jetons, numéros de série et noms de l'auteur ont été remplacés par des valeurs `<A_REMPLACER>`.

**Fourni tel quel, sans garantie.** Vous installez ceci chez vos clients et sur un serveur exposé à Internet : vous en êtes responsable. Licence : MIT (fichier `LICENSE`).

## Ce que contient le kit

| Dossier ou fichier | Niveau du tuto | Rôle |
|---|---|---|
| `serveur-pg20-info\` | 1 | Serveur RustDesk (docker-compose, `install.sh`, notice) |
| `proxmox-setup\` | 1 | Facultatif, pour Proxmox : stockage (`01-storage.sh`), VM cloud-init (`02-vm.sh`, `user-data.template.yaml`), pare-feu (`pg20-firewall.nft`) |
| `Deploy-RustDesk.ps1`, `Build-Installer.ps1`, `installer-src\` | 1 | Script d'installation et construction de l'exe |
| `Setup-Technician.ps1`, `Pg20-Common.ps1`, `Pg20-Clients.*`, `Install-Watch.ps1`, `Install-Raccourcis.ps1` | 2 | Clé du technicien, carnet de clients (et signature des ordres de désinstallation), surveillance, icônes |
| `Pg20-Agent.ps1` | 3 | Tâche de maintenance installée par l'exe chez le client : désinstalle RustDesk sur un ordre signé. Embarquée par `Build-Installer.ps1` ; ne la lancez pas à la main |
| `conditions\conditions-modele.txt`, `conditions-modele.en.txt` | 1 à 3 | Modèle des conditions d'installation que le client accepte à l'écran (français ; traduction de courtoisie en anglais) |
| `proxmox-setup\pg20-feed\` | 3 | Services de la VM : exportateur, flux, receveur, oubli, avec leurs unités systemd et scripts d'installation |
| `home-assistant\` | 3 | Capteur, secrets, automatisations, commande REST |

La disposition des dossiers est celle du projet d'origine : ne déplacez pas les fichiers, des scripts s'appellent entre eux par chemin relatif.

Les scripts `.sh` perdent leur droit d'exécution quand ils passent par Windows et une archive. Après les avoir copiés sur la VM, lancez `chmod +x *.sh` dans leur dossier (ou appelez-les avec `sudo bash ./script.sh`).

## Ce qui n'est PAS dans le kit

- **`technician.pub.xml`** : c'est la clé publique de l'auteur. Créez la vôtre avec `.\Setup-Technician.ps1`, puis sauvegardez la clé privée (`-ExportBackup`).
- **Les exes** : construisez-les avec `Build-Installer.ps1` (voir plus bas). Aucun exe de l'auteur n'est fourni, ils contiennent ses adresses.
- **L'installeur RustDesk** : à télécharger vous-même (voir `redist\A-LIRE.txt`).
- **La configuration complète de Home Assistant** : seulement les blocs à ajouter. Les scripts `pg20_valider_derniere`, `pg20_valider_et_accueil` et le tableau de bord `pg20-info` sont donnés en YAML dans le tuto.
- **Les tests automatisés** de l'auteur.

## Valeurs à remplacer

| Valeur | Où |
|---|---|
| `<IP_VM>` | `home-assistant\1-capteur-rest.yaml`, `home-assistant\5-rest-command-valider.yaml`, `proxmox-setup\02-vm.sh`, `proxmox-setup\pg20-feed\pg20-peers-feed.service` (exemples dans `Setup-Technician.ps1` et `serveur-pg20-info\LISEZMOI.md`) |
| `<IP_PASSERELLE>` | `proxmox-setup\pg20-firewall.nft`, `proxmox-setup\02-vm.sh` |
| `<RESEAU_LOCAL>`, `<RESEAU_WIREGUARD>` | `proxmox-setup\pg20-firewall.nft`, `proxmox-setup\pg20-feed\pg20-peers-feed.service` |
| `<MAC_DE_LA_VM>` | `proxmox-setup\02-vm.sh` |
| `<PERIPHERIQUE>`, `<MODELE_DU_DISQUE>`, `<NUMERO_DE_SERIE>` | `proxmox-setup\01-storage.sh` (seulement si vous dédiez un disque à la VM sous Proxmox) |
| `<TELEPHONE>` | `home-assistant\3-automation-nouveau-poste.yaml`, `home-assistant\4-fiches-recues.yaml` |
| `<DOSSIER_DU_PROJET>` | `home-assistant\2-secrets.exemple.yaml` (exemple de commande) |
| `__HASH__`, `__SSHKEY__` | `user-data.template.yaml` : remplis par `02-vm.sh` depuis `/root/pg20-setup/hash.txt` et `ssh.pub` |

Adresse publique, clé du serveur et empreinte TLS ne sont écrites dans aucun fichier du kit : elles se passent en arguments à `Build-Installer.ps1`.

Les scripts `install-feed.sh`, `install-inbox.sh` et `install-forget.sh` refusent de continuer tant qu'il reste un `<...>` dans `pg20-peers-feed.service`. `02-vm.sh` et `01-storage.sh` font de même pour leurs propres valeurs.

## Valeurs codées en dur à connaître

Ces valeurs sont des choix de l'auteur, pas des secrets. Adaptez-les si les vôtres diffèrent.

- Sur la VM : l'utilisateur d'administration s'appelle `pg20admin` et le serveur RustDesk vit dans `~/serveur-pg20-info`. Le chemin `/home/pg20admin/serveur-pg20-info/data/db_v2.sqlite3` est écrit dans `peers-export.py`, `peers-forget.py`, `pg20-forget-peer.sh`, `install-feed.sh` et `install-forget.sh`.
- `02-vm.sh` : numéro de VM `102`, stockage Proxmox `pg20-info`, 1 vCPU, 1 Go de RAM, 16 Go de disque.
- `user-data.template.yaml` : fuseau `Europe/Zurich`.
- Le pare-feu fourni est la version **niveau 3** : il ouvre le port 21120 (receveur de fiches) et 8099 (flux, réseau local et VPN). Pour les niveaux 1 et 2, retirez le jeu `inbox_flood`, les deux lignes du port 21120 et le port 8099, comme dans le tuto.
- Windows PowerShell 5.1 (celui livré avec Windows 10 et 11).

## Construire un exe (rappel)

```powershell
.\Setup-Technician.ps1        # une fois : crée votre clé, écrit technician.pub.xml
.\Build-Installer.ps1 -InstallerFile .\redist\rustdesk-1.5.0-x86_64.exe `
  -Server <ADRESSE_PUBLIQUE> -Key "<CLE_PUBLIQUE_SERVEUR>" `
  -TechnicianPublicKey .\technician.pub.xml -InboxPin <EMPREINTE_TLS> `
  -TermsFile .\conditions\conditions-AAAA-MM-JJ.txt `
  -Output .\dist\Support-Offline.exe
```

`-TermsFile` : le texte des conditions que le client doit accepter avant toute installation. Copiez `conditions\conditions-modele.txt` (ou `.en.txt`) sous un nom daté, remplissez tous les champs entre crochets, **faites-le relire**, et gardez chaque version distribuée : la preuve d'acceptation désigne le texte par son empreinte. La construction refuse un texte qui contient encore un champ entre crochets. Avec `-InboxPin` et `-TechnicianPublicKey`, l'exe embarque aussi la tâche de maintenance (`Pg20-Agent.ps1`) ; la construction exige alors un texte qui la mentionne (« tâche de maintenance » ou « maintenance task »). `-NoAgent` construit un exe sans elle : les postes se désinstallent alors par le parcours guidé.

Sans `-InstallerFile`, l'exe télécharge RustDesk au moment de l'installation. Sans `-TechnicianPublicKey` et `-InboxPin`, vous êtes au niveau 1 (pas de fiche chiffrée).

## Ce qui a été vérifié sur ce kit, et ce qui ne l'a pas été

- Vérifié : aucune des valeurs réelles de l'auteur ne reste dans les fichiers (recherche automatique) ; tous les scripts PowerShell, shell et Python passent une analyse syntaxique ; seules les lignes de valeurs ont changé par rapport aux fichiers d'origine, plus les contrôles de valeurs `<...>` des scripts d'installation, de `02-vm.sh` et de `01-storage.sh`.
- Vérifié en réel : la désinstallation automatique par la tâche de maintenance, sur un poste de test sous Windows 10. Non vérifié : le déclenchement de la tâche au démarrage du poste et la réaction des antivirus.
- Non vérifié : le kit n'a **pas** été réinstallé de zéro sur une machine vierge, ni les contrôles de valeurs `<...>` exécutés sur un vrai serveur. Les scripts d'origine, eux, tournent chez l'auteur (voir la section « Ce qui est testé » du tuto).
- Dans `home-assistant\4-fiches-recues.yaml`, la deuxième automatisation est donnée en commentaire (à recréer dans l'interface). Sa version à jour est dans le tuto.

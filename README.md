# Pg20 Info

> **English readers:** an English translation is available in [`README.en.md`](README.en.md) and [`TUTO-Pg20-Info.en.html`](TUTO-Pg20-Info.en.html). The French files are the reference.

Support à distance RustDesk auto-hébergé : votre propre serveur, un installeur Windows en un double-clic, des fiches clients chiffrées qui s'enregistrent toutes seules, et une validation depuis le téléphone.

> **Avertissement.** Ce montage ouvre des ports sur Internet et donne un accès permanent à des ordinateurs de clients. Lisez d'abord la section « Risques et garde-fous » du tuto, et ne l'utilisez qu'avec l'accord écrit de vos clients.
> Le niveau 3 installe en plus, chez chaque client, une petite tâche de maintenance en compte système : elle ne sait que désinstaller RustDesk, sur un ordre signé par votre clé. Relisez `Pg20-Agent.ps1` avant de l'utiliser.
> Le code est fourni tel quel, sans garantie et sans audit de sécurité externe. Il a été écrit avec l'aide d'un assistant IA (Claude), puis testé par son auteur dans un seul environnement : Windows 10, Debian 12 sous Proxmox, Home Assistant, Android.

## Par où commencer

1. **Le tuto** : [`TUTO-Pg20-Info.html`](TUTO-Pg20-Info.html). Téléchargez-le et ouvrez-le dans un navigateur : principe, architecture, risques, étapes, ce qui est testé et ce qui ne l'est pas.
2. **Le LISEZMOI du kit** : [`LISEZMOI-KIT.md`](LISEZMOI-KIT.md). Contenu des dossiers, valeurs à remplacer (`<IP_VM>`, `<RESEAU_LOCAL>`…), ce qui n'est pas inclus.

## Trois niveaux, à monter dans l'ordre

| Niveau | Ce que vous obtenez | Ce que vous exposez à Internet |
|---|---|---|
| 1 | Votre serveur RustDesk et un exe qui installe et règle RustDesk chez le client | Les ports RustDesk |
| 2 | Mots de passe chiffrés, carnet de clients, connexion en un clic | Rien de plus |
| 3 | Envoi direct de la fiche, notification et validation sur le téléphone, désinstallation automatique à distance | Le port TCP 21120 (service écrit pour ce projet) |

Vous pouvez vous arrêter au niveau 1 ou 2 : le niveau 3 est le seul qui expose du code maison.

## Contenu

| Dossier ou fichier | Rôle |
|---|---|
| `serveur-pg20-info/` | Serveur RustDesk (hbbs et hbbr) en Docker |
| `proxmox-setup/` | Pare-feu, VM sous Proxmox (facultatif) et services de la VM (`pg20-feed/`) |
| `Deploy-RustDesk.ps1`, `Build-Installer.ps1`, `installer-src/` | L'exe d'installation |
| `Pg20-Agent.ps1` | Tâche de maintenance installée chez le client : désinstalle RustDesk sur un ordre signé |
| `conditions/` | Modèle des conditions d'installation (français) et traduction de courtoisie en anglais |
| `Setup-Technician.ps1`, `Pg20-Clients.*`, `Install-*.ps1` | Clé du technicien, carnet de clients, surveillance, icônes |
| `home-assistant/` | Capteur, automatisations et commande REST |

## Ce qui n'est pas ici

Votre clé de technicien (`Setup-Technician.ps1` la crée), le texte de vos conditions d'installation (le modèle est fourni, à compléter et à faire relire), les exes (`Build-Installer.ps1` les construit avec vos adresses) et l'installeur RustDesk (à télécharger vous-même). Rien dans ce dépôt ne contient d'adresse, de clé ou de jeton réels.

## Statut

Fonctionne chez l'auteur. Pas encore testé : l'exe en ligne, Windows 11, d'autres antivirus (dont leur réaction à la tâche de maintenance), une session depuis un autre réseau que celui du poste de test. La désinstallation automatique a été essayée en réel sur un poste de test. Détails dans le tuto, section « Ce qui est testé ».

## Signaler un problème de sécurité

Ne décrivez pas une faille dans une issue publique. Utilisez le signalement privé de GitHub (voir [`SECURITY.md`](SECURITY.md)).

## Licence

Voir le fichier `LICENSE` (licence MIT, en anglais : c'est lui qui fait foi). Une traduction française de courtoisie est dans [`LICENSE.fr.txt`](LICENSE.fr.txt).

RustDesk est une marque de ses propriétaires. Ce projet n'a aucun lien avec eux.

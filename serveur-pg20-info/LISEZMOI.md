# Serveur RustDesk « Pg20 Info »

Serveur à héberger chez vous (NAS, Raspberry, mini-PC Linux avec Docker), joignable par votre **IP publique fixe**.

## 1. Installer
Copiez ce dossier sur la machine, puis lancez le script :

```bash
scp -r serveur-pg20-info utilisateur@IP_LOCALE_DE_LA_MACHINE:~/
ssh utilisateur@IP_LOCALE_DE_LA_MACHINE
cd serveur-pg20-info && chmod +x install.sh && ./install.sh
```

Le script demande votre IP publique fixe, démarre `pg20-info-hbbs` et `pg20-info-hbbr`, puis affiche l'**adresse** et la **clé publique** (aussi écrites dans `client-settings.txt`).

## 2. Ouvrir les ports sur la box
Redirigez (NAT/PAT) vers l'IP locale de la machine :

| Port | Protocole | Rôle |
|---|---|---|
| 21115 | TCP | test de type de NAT |
| 21116 | **TCP et UDP** | enregistrement des postes, mise en relation |
| 21117 | TCP | relais |

Les clients, eux, n'ont besoin que d'une connexion sortante.

Vérifications utiles :
- Depuis l'extérieur (par exemple en 4G), `nc -vz VOTRE_IP 21116` doit répondre « succeeded ».
- Si ce n'est pas le cas, comparez l'IP « WAN » de votre box avec votre IP publique : si elles diffèrent, votre opérateur fait du CGNAT et la redirection de ports ne marchera pas.

## 3. Construire l'exe client (sur votre PC Windows)
La commande exacte est dans `client-settings.txt`. En résumé :

```powershell
.\Build-Installer.ps1 -InstallerFile .\redist\rustdesk-1.5.0-x86_64.exe -Server VOTRE_IP -Key "VOTRE_CLE" -Output .\dist\Pg20-Info-Support.exe
```

## 4. À savoir
- **Sauvegardez `data/id_ed25519`** (clé privée). Si elle est perdue, le serveur génère une nouvelle clé et tous les clients doivent être reconfigurés avec un nouvel exe.
- `-k _` est activé : un client qui n'a pas la clé de ce serveur est refusé.
- Mise à jour : `docker compose pull && docker compose up -d`
- Journaux : `docker compose logs -f hbbs`
- Arrêt : `docker compose down` (les données restent dans `./data`).
- Si vous changez d'IP publique, relancez `./install.sh` avec la nouvelle adresse, supprimez la ligne `RD_HOST` de `.env` avant, et reconstruisez les exes.

## 5. Sous Proxmox, à côté de Home Assistant
Home Assistant OS tourne dans sa propre VM : n'y installez pas Docker. Créez une machine séparée sur le même Proxmox.

**Option recommandée : petite VM Debian 12** (1 vCPU, 1 Go de RAM, 8 Go de disque, réseau `vmbr0`). C'est la plus robuste : Proxmox déconseille Docker dans un LXC.

**Option plus légère : conteneur LXC Debian 12** (non privilégié) avec, dans *Options → Features*, **Nesting** et **keyctl** cochés. Si le stockage est en ZFS, Docker peut avoir des soucis dans un LXC : prenez alors la VM.

Dans les deux cas :
1. **IP fixe sur le réseau local** (hors plage DHCP de la box), par exemple 192.168.1.60. Vos redirections de ports pointeront vers elle.
2. Installer Docker : `curl -fsSL https://get.docker.com | sh`
3. Depuis votre PC Windows (OpenSSH est intégré) :
   ```powershell
   scp -r .\serveur-pg20-info root@<IP_VM>:~/
   ssh root@<IP_VM> "cd serveur-pg20-info && chmod +x install.sh && ./install.sh"
   ```
4. Redirections de ports de la box vers cette IP (voir §2).
5. Ajouter la VM/le LXC à la sauvegarde Proxmox : le dossier `data/` contient la clé privée.

**Utiliser le serveur depuis votre PC** (le RustDesk du technicien) : *Paramètres → Réseau → Serveur ID / Relais* : votre IP publique, et la clé. Si ça ne marche que depuis chez vous, la box n'a probablement pas de « NAT loopback » : mettez alors l'IP **locale** (<IP_VM>) dans les champs serveur ID et relais de votre PC uniquement. Les clients distants gardent l'IP publique.

# Pg20 Info kit (sanitised version)

> **This is an English translation of [`LISEZMOI-KIT.md`](LISEZMOI-KIT.md).** The French file is the reference; if the two disagree, the French one is right. Translated with the help of an AI assistant, not proofread by a native speaker. File contents, script messages and on-screen texts remain in French.

Scripts of the setup described in `TUTO-Pg20-Info.html` / `TUTO-Pg20-Info.en.html` (read it first, especially the "Risks and safeguards" section).
Kit sanitised on 2026-10-03, updated on 2026-10-04 (terms, proof of acceptance, uninstallation, maintenance task): the author's addresses, keys, fingerprints, tokens, serial numbers and names have been replaced by `<A_REMPLACER>`-style values.

**Provided as is, without warranty.** You install this at your clients' and on a server exposed to the Internet: you are responsible for it. Licence: MIT (`LICENSE` file).

## What the kit contains

| Folder or file | Tutorial level | Role |
|---|---|---|
| `serveur-pg20-info\` | 1 | RustDesk server (docker-compose, `install.sh`, notes) |
| `proxmox-setup\` | 1 | Optional, for Proxmox: storage (`01-storage.sh`), cloud-init VM (`02-vm.sh`, `user-data.template.yaml`), firewall (`pg20-firewall.nft`) |
| `Deploy-RustDesk.ps1`, `Build-Installer.ps1`, `installer-src\` | 1 | Installation script and exe build |
| `Setup-Technician.ps1`, `Pg20-Common.ps1`, `Pg20-Clients.*`, `Install-Watch.ps1`, `Install-Raccourcis.ps1` | 2 | Technician key, client address book (and signing of uninstall orders), background watcher, icons |
| `Pg20-Agent.ps1` | 3 | Maintenance task installed by the exe at the client's: uninstalls RustDesk on a signed order. Embedded by `Build-Installer.ps1`; do not run it by hand |
| `conditions\conditions-modele.txt`, `conditions-modele.en.txt` | 1 to 3 | Template of the installation terms that the client accepts on screen (French; courtesy translation in English) |
| `proxmox-setup\pg20-feed\` | 3 | VM services: exporter, feed, receiver, forget service, with their systemd units and install scripts |
| `home-assistant\` | 3 | Sensor, secrets, automations, REST command |

The folder layout is that of the original project: do not move files, scripts call each other by relative path.

`.sh` scripts lose their execute permission when they go through Windows and an archive. After copying them to the VM, run `chmod +x *.sh` in their folder (or call them with `sudo bash ./script.sh`).

## What is NOT in the kit

- **`technician.pub.xml`**: this is the author's public key. Create yours with `.\Setup-Technician.ps1`, then back up the private key (`-ExportBackup`).
- **The exes**: build them with `Build-Installer.ps1` (see below). None of the author's exes is provided, they contain his addresses.
- **The RustDesk installer**: download it yourself (see `redist\A-LIRE.txt`).
- **The complete Home Assistant configuration**: only the blocks to add. The `pg20_valider_derniere` and `pg20_valider_et_accueil` scripts and the `pg20-info` dashboard are given as YAML in the tutorial.
- **The author's automated tests.**

## Values to replace

| Value | Where |
|---|---|
| `<IP_VM>` | `home-assistant\1-capteur-rest.yaml`, `home-assistant\5-rest-command-valider.yaml`, `proxmox-setup\02-vm.sh`, `proxmox-setup\pg20-feed\pg20-peers-feed.service` (examples in `Setup-Technician.ps1` and `serveur-pg20-info\LISEZMOI.md`) |
| `<IP_PASSERELLE>` (gateway IP) | `proxmox-setup\pg20-firewall.nft`, `proxmox-setup\02-vm.sh` |
| `<RESEAU_LOCAL>`, `<RESEAU_WIREGUARD>` (local network, WireGuard network) | `proxmox-setup\pg20-firewall.nft`, `proxmox-setup\pg20-feed\pg20-peers-feed.service` |
| `<MAC_DE_LA_VM>` | `proxmox-setup\02-vm.sh` |
| `<PERIPHERIQUE>`, `<MODELE_DU_DISQUE>`, `<NUMERO_DE_SERIE>` (device, disk model, serial number) | `proxmox-setup\01-storage.sh` (only if you dedicate a disk to the VM under Proxmox) |
| `<TELEPHONE>` (phone) | `home-assistant\3-automation-nouveau-poste.yaml`, `home-assistant\4-fiches-recues.yaml` |
| `<DOSSIER_DU_PROJET>` (project folder) | `home-assistant\2-secrets.exemple.yaml` (example command) |
| `__HASH__`, `__SSHKEY__` | `user-data.template.yaml`: filled in by `02-vm.sh` from `/root/pg20-setup/hash.txt` and `ssh.pub` |

The public address, the server key and the TLS fingerprint are not written in any file of the kit: they are passed as arguments to `Build-Installer.ps1`.

`install-feed.sh`, `install-inbox.sh` and `install-forget.sh` refuse to continue while a `<...>` remains in `pg20-peers-feed.service`. `02-vm.sh` and `01-storage.sh` do the same for their own values.

## Hard-coded values to know about

These values are the author's choices, not secrets. Adapt them if yours differ.

- On the VM: the administration user is called `pg20admin` and the RustDesk server lives in `~/serveur-pg20-info`. The path `/home/pg20admin/serveur-pg20-info/data/db_v2.sqlite3` is written in `peers-export.py`, `peers-forget.py`, `pg20-forget-peer.sh`, `install-feed.sh` and `install-forget.sh`.
- `02-vm.sh`: VM number `102`, Proxmox storage `pg20-info`, 1 vCPU, 1 GB RAM, 16 GB disk.
- `user-data.template.yaml`: time zone `Europe/Zurich`.
- The supplied firewall is the **level 3** version: it opens port 21120 (client-record receiver) and 8099 (feed, local network and VPN). For levels 1 and 2, remove the `inbox_flood` set, the two port-21120 lines and port 8099, as in the tutorial.
- Windows PowerShell 5.1 (the one shipped with Windows 10 and 11).

## Building an exe (reminder)

```powershell
.\Setup-Technician.ps1        # once: creates your key, writes technician.pub.xml
.\Build-Installer.ps1 -InstallerFile .\redist\rustdesk-1.5.0-x86_64.exe `
  -Server <PUBLIC_ADDRESS> -Key "<SERVER_PUBLIC_KEY>" `
  -TechnicianPublicKey .\technician.pub.xml -InboxPin <TLS_FINGERPRINT> `
  -TermsFile .\conditions\conditions-YYYY-MM-DD.txt `
  -Output .\dist\Support-Offline.exe
```

`-TermsFile`: the text of the terms the client must accept before anything is installed. Copy `conditions\conditions-modele.txt` (or `.en.txt`) under a dated name, fill in every field in square brackets, **have it reviewed**, and keep every version you distribute: the proof of acceptance designates the text by its fingerprint. The build refuses a text that still contains a field in square brackets. With `-InboxPin` and `-TechnicianPublicKey`, the exe also embeds the maintenance task (`Pg20-Agent.ps1`); the build then requires a text that mentions it ("tâche de maintenance" or "maintenance task"). `-NoAgent` builds an exe without it: those computers are then uninstalled through the guided procedure.

Without `-InstallerFile`, the exe downloads RustDesk at installation time. Without `-TechnicianPublicKey` and `-InboxPin`, you are at level 1 (no encrypted client record).

## What has been checked on this kit, and what has not

- Checked: none of the author's real values remains in the files (automatic search); all PowerShell, shell and Python scripts pass a syntax check; only value lines changed compared with the original files, plus the `<...>` value checks of the install scripts, of `02-vm.sh` and of `01-storage.sh`.
- Checked for real: the automatic uninstallation by the maintenance task, on a Windows 10 test computer. Not checked: the firing of the task at the computer's start-up and the antivirus reaction.
- Not checked: the kit has **not** been reinstalled from scratch on a clean machine, nor have the `<...>` value checks been run on a real server. The original scripts, however, run at the author's (see the "What is tested" section of the tutorial).
- In `home-assistant\4-fiches-recues.yaml`, the second automation is given as a comment (to be recreated in the interface). Its up-to-date version is in the tutorial.

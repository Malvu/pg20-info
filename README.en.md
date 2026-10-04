# Pg20 Info

> **This is an English translation of [`README.md`](README.md), written for readers who do not read French.** The French files are the reference: if the two ever disagree, the French one is right. The scripts, the client-facing screens and the messages of the tools are in French; only the documentation has been translated. The translation was produced with the help of an AI assistant and has not been proofread by a native speaker.

Self-hosted RustDesk remote support: your own server, a one-double-click Windows installer, encrypted client records that register themselves, and validation from your phone.

> **Warning.** This setup opens ports to the Internet and gives permanent access to clients' computers. First read the "Risks and safeguards" section of the tutorial, and use it only with your clients' written agreement.
> Level 3 also installs, on every client computer, a small maintenance task running as the system account: it can only uninstall RustDesk, on an order signed by your key. Read `Pg20-Agent.ps1` before using it.
> The code is provided as is, without warranty and without an external security audit. It was written with the help of an AI assistant (Claude), then tested by its author in a single environment: Windows 10, Debian 12 under Proxmox, Home Assistant, Android.

## Where to start

1. **The tutorial**: [`TUTO-Pg20-Info.en.html`](TUTO-Pg20-Info.en.html) (English translation) or [`TUTO-Pg20-Info.html`](TUTO-Pg20-Info.html) (French original). Download it and open it in a browser: principle, architecture, risks, steps, what is tested and what is not.
2. **The kit README**: [`LISEZMOI-KIT.en.md`](LISEZMOI-KIT.en.md) (translation of [`LISEZMOI-KIT.md`](LISEZMOI-KIT.md)). Folder contents, values to replace (`<IP_VM>`, `<RESEAU_LOCAL>`…), what is not included.

## Three levels, to be built in order

| Level | What you get | What you expose to the Internet |
|---|---|---|
| 1 | Your own RustDesk server and an exe that installs and configures RustDesk at the client's | The RustDesk ports |
| 2 | Encrypted passwords, a client address book, one-click connection | Nothing more |
| 3 | Direct sending of the client record, notification and validation on the phone, automatic remote uninstallation | TCP port 21120 (a service written for this project) |

You can stop at level 1 or 2: level 3 is the only one that exposes home-made code.

## Contents

| Folder or file | Role |
|---|---|
| `serveur-pg20-info/` | RustDesk server (hbbs and hbbr) in Docker |
| `proxmox-setup/` | Firewall, VM under Proxmox (optional) and the VM services (`pg20-feed/`) |
| `Deploy-RustDesk.ps1`, `Build-Installer.ps1`, `installer-src/` | The installer exe |
| `Pg20-Agent.ps1` | Maintenance task installed at the client's: uninstalls RustDesk on a signed order |
| `conditions/` | Template of the installation terms (French) and a courtesy translation in English |
| `Setup-Technician.ps1`, `Pg20-Clients.*`, `Install-*.ps1` | Technician key, client address book, background watcher, desktop icons |
| `home-assistant/` | Sensor, automations and REST command |

## What is not here

Your technician key (`Setup-Technician.ps1` creates it), the text of your own installation terms (a template is provided, to be completed and reviewed), the exes (`Build-Installer.ps1` builds them with your addresses) and the RustDesk installer (download it yourself). Nothing in this repository contains a real address, key or token.

## Status

Works for the author. Not tested yet: the online exe, Windows 11, other antivirus programs (including their reaction to the maintenance task), a session from a network other than the test computer's. The automatic uninstallation has been tried for real on a test computer.

## Reporting a security problem

Do not describe a vulnerability in a public issue. Use GitHub's private reporting (see [`SECURITY.en.md`](SECURITY.en.md)).

## Licence

See the `LICENSE` file.

RustDesk is a trademark of its owners. This project has no connection with them.

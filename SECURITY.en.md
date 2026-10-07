# Reporting a security vulnerability

> English translation of [`SECURITY.md`](SECURITY.md). The French text is the reference. Translated with the help of an AI assistant.

Do not describe a vulnerability in a public issue or discussion.

Use GitHub's private reporting: **Security** tab, then **Report a vulnerability**. The project is maintained by one person: replies are made on a best-effort basis, with no guaranteed delay.

## What matters most

In order of exposure:

1. `proxmox-setup/pg20-feed/inbox-receive.py`: the receiver of client records and orders, reachable from the Internet on TCP 21120 (including `GET /v1/order` and `POST /v1/order-done`).
2. `Pg20-Client-Maintenance.ps1`: the maintenance task, running as the system account on the client's computer. Verification of the signed orders, permissions of its installation folder, what it agrees to execute.
3. `Pg20-Client-Installation.ps1` and the installer exe: they run as administrator on the client's computer.
4. `proxmox-setup/pg20-feed/peers-feed.py` and `peers-forget.py`: local network and VPN only, but they act on the server's database and drop the signed orders.
5. `Pg20-Clients-Carnet.ps1` and `Pg20-Commun.ps1`: the technician's address book, the decryption of client records and the signing of orders.

Describe what you observed, how to reproduce it, and on which version (or commit).

## What is not a vulnerability of this project

- A defect in RustDesk itself: report it to its publishers.
- The SmartScreen or antivirus warning on an unsigned exe: this is known and described in the tutorial.

Only the latest version is supported.

Français : voir [`SECURITY.md`](SECURITY.md).

# Signaler une faille de sécurité

Ne décrivez pas une faille dans une issue ou une discussion publique.

Utilisez le signalement privé de GitHub : onglet **Security**, puis **Report a vulnerability**. Le projet est maintenu par une seule personne : les réponses se font au mieux, sans délai garanti.

## Ce qui compte le plus

Par ordre d'exposition :

1. `proxmox-setup/pg20-feed/inbox-receive.py` : le receveur de fiches, joignable depuis Internet sur TCP 21120.
2. `Deploy-RustDesk.ps1` et l'exe d'installation : ils tournent en administrateur chez le client.
3. `proxmox-setup/pg20-feed/peers-feed.py` et `peers-forget.py` : réseau local et VPN seulement, mais ils agissent sur la base du serveur.
4. `Pg20-Clients.ps1` : le carnet du technicien et le déchiffrement des fiches.

Décrivez ce que vous avez observé, comment le reproduire, et sur quelle version (ou quel commit).

## Ce qui n'est pas une faille de ce projet

- Un défaut de RustDesk lui-même : signalez-le à ses éditeurs.
- L'avertissement SmartScreen ou d'un antivirus sur un exe non signé : c'est connu et décrit dans le tuto.

Seule la dernière version est suivie.

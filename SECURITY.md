# Signaler une faille de sécurité

Ne décrivez pas une faille dans une issue ou une discussion publique.

Utilisez le signalement privé de GitHub : onglet **Security**, puis **Report a vulnerability**. Le projet est maintenu par une seule personne : les réponses se font au mieux, sans délai garanti.

## Ce qui compte le plus

Par ordre d'exposition :

1. `proxmox-setup/pg20-feed/inbox-receive.py` : le receveur de fiches et d'ordres, joignable depuis Internet sur TCP 21120 (y compris `GET /v1/order` et `POST /v1/order-done`).
2. `Pg20-Agent.ps1` : la tâche de maintenance, en compte système chez le client. Vérification de la signature des ordres, droits du dossier d'installation, choix de ce qu'elle accepte d'exécuter.
3. `Deploy-RustDesk.ps1` et l'exe d'installation : ils tournent en administrateur chez le client.
4. `proxmox-setup/pg20-feed/peers-feed.py` et `peers-forget.py` : réseau local et VPN seulement, mais ils agissent sur la base du serveur et déposent les ordres signés.
5. `Pg20-Clients.ps1` et `Pg20-Common.ps1` : le carnet du technicien, le déchiffrement des fiches et la signature des ordres.

Décrivez ce que vous avez observé, comment le reproduire, et sur quelle version (ou quel commit).

## Ce qui n'est pas une faille de ce projet

- Un défaut de RustDesk lui-même : signalez-le à ses éditeurs.
- L'avertissement SmartScreen ou d'un antivirus sur un exe non signé : c'est connu et décrit dans le tuto.

Seule la dernière version est suivie.

English: see [`SECURITY.en.md`](SECURITY.en.md) (translation; the French text is the reference).

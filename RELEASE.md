# Release - Nextcloud interne derrière Traefik

Version : 1.0.0  
Date : 2026-07-01  
Cible : Debian 12, Nextcloud dernière version stable disponible, Apache php-fpm, MariaDB, Redis, Traefik en frontal.

## Contenu

- `install-nextcloud-prod.sh` : script d'installation production interne.
- `nextcloud-install.var` : fichier de variables à adapter avant exécution.
- `RELEASE.md` : notes de release et procédure.

## Hypothèses retenues

- Nextcloud est publié par Traefik.
- Apache est uniquement un backend interne.
- Le certificat Apache autosigné est accepté côté backend, car Traefik termine le HTTPS utilisateur.
- La VM Nextcloud ne doit pas être exposée directement aux utilisateurs.
- Les sauvegardes VM sont faites avec Proxmox Backup Server.
- Le script crée aussi un dump MariaDB applicatif utilisable avant snapshot PBS.
- La version Nextcloud installée est la dernière version stable détectée au moment de l'installation.

## Changements par rapport au script initial

- Suppression des valeurs SMTP factices appliquées par défaut.
- Ajout d'un fichier de variables externe.
- Vérification PGP et SHA-512 devenue bloquante.
- Refus de continuer si Nextcloud est déjà installé, sauf `FORCE_REINSTALL=true`.
- Passage clair sur Apache + PHP-FPM, sans `mod_php`.
- Configuration reverse proxy Nextcloud : `trusted_proxies`, `overwritehost`, `overwriteprotocol`, `overwrite.cli.url`.
- Redis configuré en socket Unix local.
- Configuration MariaDB dans `/etc/mysql/mariadb.conf.d/60-nextcloud.cnf`, sans écraser `/etc/mysql/my.cnf`.
- Secrets générés stockés en root-only dans `/root/nextcloud-install-secrets.env`.
- Création d'un script `/usr/local/sbin/nextcloud-app-backup.sh` pour générer un dump MariaDB cohérent.
- Ajout d'un logrotate dédié pour les logs Apache Nextcloud.

## Procédure d'installation

1. Copier les fichiers sur la VM Debian 12.
2. Modifier `nextcloud-install.var` :
   - `NC_FQDN`
   - `TRAEFIK_PROXY_IPS`
   - `PHP_VERSION` si nécessaire
   - paramètres SMTP uniquement si utilisés
3. Lancer :

```bash
sudo bash install-nextcloud-prod.sh ./nextcloud-install.var
```

4. Récupérer les identifiants générés :

```bash
sudo cat /root/nextcloud-install-secrets.env
```

5. Configurer Traefik vers le backend Apache :

```text
https://IP_VM_NEXTCLOUD:443
```

6. Filtrer l'accès direct à la VM Nextcloud : seul Traefik doit accéder au port backend Apache.

## Sauvegarde PBS

PBS peut sauvegarder toute la VM, mais pour avoir une base cohérente, exécuter avant snapshot :

```bash
sudo /usr/local/sbin/nextcloud-app-backup.sh
```

Éléments importants à conserver dans la VM :

```text
/var/www/nextcloud
/var/www/data
/var/backups/nextcloud
/etc/nextcloud-install
/root/nextcloud-install-secrets.env
/etc/apache2
/etc/php
/etc/mysql
/etc/redis
```

## Points à valider avant prod

- DNS `NC_FQDN` résout vers Traefik.
- Traefik joint bien le backend Apache.
- Accès direct VM Nextcloud bloqué hors Traefik.
- Test de restauration PBS effectué.
- Mot de passe admin Nextcloud changé après première connexion.
- SMTP configuré uniquement si utile.
- Supervision disque, CPU, RAM, service Apache, MariaDB, Redis et cron en place.

## Limites connues

- Le script est prévu pour installation neuve, pas pour mise à jour d'une instance existante.
- `NEXTCLOUD_VERSION="latest"` assume volontairement le risque d'une version majeure récente.
- Debian 12 fournit PHP 8.2 par défaut ; si la dernière version Nextcloud exige une version PHP plus récente, l'installation échouera ou devra être adaptée.
- Le pare-feu n'est pas configuré automatiquement pour éviter de couper l'accès d'administration.

# 🚀 Script d'installation automatisée de Nextcloud (ConfAuto-Nextcloud)

## 📋 Objectif
Installer et configurer automatiquement un serveur Nextcloud durci, auto-hébergé et prêt à l'emploi sur une machine Debian 12, avec sécurisation conforme aux recommandations de l'ANSSI.


## ✅ Points conformes aux bonnes pratiques

| Domaine                       | Évaluation                                                                            |
|------------------------------|---------------------------------------------------------------------------------------|
| Authentification MariaDB     | Passage en mode `unix_socket` pour `root` ✅                                          |
| Création aléatoire DB/user   | Génération robuste avec `openssl rand` et `/dev/urandom` ✅                           |
| Configuration Apache HTTPS   | Certificat autosigné + headers de sécurité HTTPS ✅                                   |
| Environnement séparé         | `/var/www/nextcloud`, `/var/www/data` avec droits `www-data` ✅                        |
| Signature GPG                | Vérification PGP de l’archive via `.asc` ✅                                           |
| Hash SHA512                  | Comparaison attendue vs obtenue manuellement ✅                                       |
| Crontab `www-data`           | Ajout automatique de la tâche cron Nextcloud ✅                                       |

## ⚠️ Points perfectibles (installateur uniquement)

| Catégorie                    | Détail                                                                       | Recommandation                                      |
|-----------------------------|------------------------------------------------------------------------------|-----------------------------------------------------|
| Tolérance à l’erreur        | Erreurs GPG/SHA ignorées sans arrêt ou avertissement fort                   | Ajouter un mode `--strict` pour forcer l’arrêt      |
| Logs d’installation         | Aucune trace laissée des actions effectuées                                 | Ajouter log vers `/var/log/nextcloud-install.log`   |
| Validation utilisateur root | Pas de contrôle sur l’utilisateur en exécution                              | Ajouter `[[ $EUID -ne 0 ]] && exit 1`               |
| Téléchargements `curl`      | Manque `--tlsv1.2` et `--proto` pour durcir TLS                              | Ajouter options sécurisées à `curl`                 |


## 🧩 Étapes du script

### ✅ Préparation système
- Met à jour le système, modifie les dépôts nécessaires.
- Installe les paquets de base (curl, unzip, MariaDB, Apache2, PHP, Redis...).

### 🔐 Sécurisation de MariaDB
- Supprime les utilisateurs anonymes et la base `test`.
- Active l’authentification `unix_socket` pour root.
- Génère une base Nextcloud + utilisateur + mot de passe aléatoires.
- Sauvegarde des identifiants dans un fichier local sécurisé.

### 📦 Récupération et vérification Nextcloud
- Télécharge la dernière version de Nextcloud.
- Vérifie la signature PGP.
- Vérifie l'intégrité via SHA-512.
- Décompresse dans `/var/www/nextcloud`.

### 🌐 Configuration Apache2 HTTPS
- Active les modules nécessaires (SSL, rewrite, headers).
- Crée un certificat autosigné.
- Génère un VirtualHost sécurisé (avec headers ANSSI).
- Redémarre Apache2.

### 🧠 Configuration de base Nextcloud via OCC
- Configure Redis comme memcache.
- Définit la région téléphonique, l’adresse mail, SMTP, etc.
- Répare les fichiers, configure la fenêtre de maintenance.

### 🔁 Cron Nextcloud
- Ajoute la tâche cron pour l’exécution de `cron.php` toutes les 5 minutes (si non présente).

---

## 📁 Fichier généré
Un fichier `idbdd.txt` est stocké dans `/home/<user>/nxt/` contenant :

- 📂 Nom de la base de données
- 👤 Nom d’utilisateur
- 🔐 Mot de passe

---

## 🛠️ Dépendances
- Debian 12
- Apache2
- PHP 8.2
- MariaDB
- Redis
- GPG


---

## 📌 Notes de sécurité
- Le script tente de s'approcher des recommandations issues des guides de l’[ANSSI](https://www.ssi.gouv.fr).
- L’installation se fait **entièrement en local** sans service cloud ou DNS.
- Le certificat est autosigné (à personnaliser si besoin).

---

## 🧑‍💻 Auteur
Script proposé par **NihyLix**  
🔗 [github.com/NihyLix/ConfAuto-Nextcloud](https://github.com/NihyLix/ConfAuto-Nextcloud)


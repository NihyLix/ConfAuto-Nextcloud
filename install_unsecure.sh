#############
# ETAPE 1
#############
#!/bin/bash
set -e

echo "🔍 Vérification de la version Debian"
source /etc/os-release
if [[ "$VERSION_ID" != "12" ]]; then
  echo "❌ Ce script est prévu pour Debian 12 uniquement."
  exit 1
fi

echo "🧽 Nettoyage des dépôts existants"
cp /etc/apt/sources.list /etc/apt/sources.list.bak

echo "🧽 Nettoyage des fichiers existants"
# Détermination de l’utilisateur courant
USER=${SUDO_USER:-$(id -un)}
DB_INFO_FILE="/home/${USER}/nxt/idbdd.txt"

# Si le fichier existe, on le supprime, sinon on continue
if [[ -f "$DB_INFO_FILE" ]]; then
  echo "⚠️ Ancien fichier de credentials trouvé, suppression…"
  rm -f "$DB_INFO_FILE"
fi


# Fichier à patcher
SRC="/etc/apt/sources.list"
BACKUP="${SRC}.bak"

# Sauvegarde
cp "$SRC" "$BACKUP"

# Commenter toutes les lignes deb contenant "bookworm" (suites bookworm, bookworm-security, bookworm-updates) avec composant "main"
grep -E '^deb\s+\S+\s+bookworm(-security|-updates)?\s+main' "$SRC" | while read -r line; do
  # Échapper les slashs pour sed
  esc=$(printf '%s\n' "$line" | sed 's/[\/&]/\\&/g')
  sed -i "s/^${esc}/# &/" "$SRC"
done

echo "✅ Les entrées bookworm/* main ont été commentées dans $SRC"

cat <<EOF > /etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main
deb http://security.debian.org/debian-security bookworm-security main
deb http://deb.debian.org/debian bookworm-updates main
EOF

echo "🔄 Mise à jour des paquets"
apt update -y
apt upgrade -y

echo "✅ Dépôts Debian nettoyés et mis à jour (bookworm/main + security)"


#############
# ETAPE 2
#############

echo "📦 Installation des paquets nécessaires pour Nextcloud"

# Paquets de base
apt install -y \
  curl \
  unzip \
  mariadb-server \
  apache2 \
  php-fpm \
  php8.2 \
  libapache2-mod-php8.2 \
  php8.2-curl \
  php8.2-xml \
  php-common \
  php8.2-gd \
  php8.2-mbstring \
  php8.2-zip \
  php8.2-ldap \
  libsmbclient \
  php-imap \
  php8.2-bcmath \
  php8.2-gmp \
  php8.2-intl \
  php8.2-mysql \
  php8.2-bz2 \
  php-memcache \
  php-redis \
  redis-server \
  php-imagick \
  libmagickcore-6.q16-6-extra

echo "✅ Tous les paquets requis sont installés."

# (Optionnel) Affichage des versions installées pour vérification
echo -e "\n🔎 Vérification versions principales :"
php -v | head -n1
apache2 -v | grep version
mysql --version
redis-server --version


#############
# ETAPE 3
#############

# === Génération des identifiants ===
DB_NAME="nxt_$(tr -dc 0-9 </dev/urandom | head -c 6)"
DB_USER="usrnxt_$(tr -dc 0-9 </dev/urandom | head -c 6)"
DB_PASS=$(openssl rand -base64 21)

# === Génération de l'emplacement d'enregistrement ===
USER=${SUDO_USER:-$(id -un)}
mkdir -p "/home/${USER}/nxt"
DB_INFO_FILE="/home/${USER}/nxt/idbdd.txt"

# === Sécurisation basique MariaDB ===
echo "⚙️ Sécurisation de MariaDB..."

mysql -u root <<EOF
-- Suppression utilisateurs anonymes
DELETE FROM mysql.user WHERE User='';
-- Suppression accès root à distance
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
-- Suppression base de test
DROP DATABASE IF EXISTS test;
-- Rechargement des privilèges
FLUSH PRIVILEGES;
EOF

echo "✅ MariaDB sécurisée"

# === Création de la base et de l’utilisateur ===
echo "📦 Création base de données Nextcloud : $DB_NAME"

mysql -u root <<EOF
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# === Checklist finale ===
echo -e "\n================== ✅ IDENTIFIANTS NEXTCLOUD ==================" >> $DB_INFO_FILE
echo "📂 Base de données : $DB_NAME" >> $DB_INFO_FILE
echo "👤 Utilisateur      : $DB_USER" >> $DB_INFO_FILE
echo "🔐 Mot de passe     : $DB_PASS" >> $DB_INFO_FILE
echo "===============================================================" >> $DB_INFO_FILE
cat $DB_INFO_FILE

#############
# ETAPE 4
#############

echo "⚙️ Optimisation de MariaDB (/etc/mysql/my.cnf)"

cat <<EOF > /etc/mysql/my.cnf
[server]
skip_name_resolve = 1
innodb_buffer_pool_size = 128M
innodb_buffer_pool_instances = 1
innodb_flush_log_at_trx_commit = 2
innodb_log_buffer_size = 32M
innodb_max_dirty_pages_pct = 90
query_cache_type = 1
query_cache_limit = 2M
query_cache_min_res_unit = 2k
query_cache_size = 64M
tmp_table_size = 64M
max_heap_table_size = 64M
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1

[client-server]
!includedir /etc/mysql/conf.d/
!includedir /etc/mysql/mariadb.conf.d/

[client]
default-character-set = utf8mb4

[mysqld]
character_set_server = utf8mb4
collation_server = utf8mb4_general_ci
transaction_isolation = READ-COMMITTED
binlog_format = ROW
innodb_large_prefix = on
innodb_file_format = barracuda
innodb_file_per_table = 1
EOF

echo "✅ my.cnf optimisé."

echo "⚙️ Optimisation PHP (/etc/php/8.2/apache2/php.ini)"

PHPINI="/etc/php/8.2/apache2/php.ini"

# Appliquer les paramètres recommandés
sed -i "s/^memory_limit = .*/memory_limit = 512M/" "$PHPINI"
sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 15G/" "$PHPINI"
sed -i "s/^max_execution_time = .*/max_execution_time = 360/" "$PHPINI"
sed -i "s/^output_buffering = .*/output_buffering = Off/" "$PHPINI"
sed -i "s|^;*date.timezone =.*|date.timezone = Europe/Paris|" "$PHPINI"

# Autres améliorations recommandées
if ! grep -q "opcache.enable=1" "$PHPINI"; then
cat <<EOF >> "$PHPINI"

[opcache]
opcache.enable=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.revalidate_freq=1
EOF
fi

if ! grep -q "apc.enable_cli=1" "$PHPINI"; then
echo -e "\n[apcu]\napc.enable_cli=1" >> "$PHPINI"
fi

echo "✅ php.ini optimisé."

echo "🔄 Redémarrage des services"
systemctl restart apache2
systemctl restart mariadb



#############
# ETAPE 5
#############

echo "📁 Création de l'arborescence Nextcloud"
mkdir -p /var/www/nextcloud
mkdir -p /var/www/data
mkdir -p /etc/ssl/apache2/nextcloud
mkdir -p /var/log/apache2/nextcloud
chown -R www-data:www-data /var/www/

echo "🔐 Génération certificat SSL autosigné"
openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
  -keyout /etc/ssl/apache2/nextcloud/nxt.key \
  -out /etc/ssl/apache2/nextcloud/nxt.pem \
  -subj "/C=FR/ST=Ile-de-France/L=Paris/O=Nextcloud/CN=localhost"

echo "🔧 Nettoyage des vhosts par défaut"
a2dissite 000-default.conf default-ssl.conf || true
rm -f /etc/apache2/sites-enabled/*

echo "⚙️ Création du VHost /etc/apache2/sites-available/nextcloud.conf"
cat <<EOF > /etc/apache2/sites-available/nextcloud.conf
<VirtualHost *:443>
    ServerName localhost
    DocumentRoot /var/www/nextcloud

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    # Logs
    ErrorLog /var/log/apache2/nextcloud/errors.log
    CustomLog /var/log/apache2/nextcloud/access.log combined
    LogLevel warn

    # SSL
    SSLEngine on
    SSLCertificateFile /etc/ssl/apache2/nextcloud/nxt.pem
    SSLCertificateKeyFile /etc/ssl/apache2/nextcloud/nxt.key

    # Sécurité - En-têtes ANSSI
    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        Header always set Referrer-Policy "no-referrer"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-XSS-Protection "1; mode=block"
    </IfModule>
</VirtualHost>
EOF

echo "🧩 Activation des modules Apache nécessaires"
a2enmod ssl rewrite headers env dir mime http2

echo "📡 Activation du site nextcloud.conf"
a2ensite nextcloud.conf

echo "🔄 Redémarrage Apache"
systemctl reload apache2

echo "✅ VHost HTTPS sécurisé prêt : https://localhost"



#############
# ETAPE 6
#############

# === Variables ===
NEXTCLOUD_VERSION=$(curl -s https://download.nextcloud.com/server/releases/ | grep -Eo 'nextcloud-[0-9]+\.[0-9]+\.[0-9]+\.zip' | sort -V | tail -n1)
NEXTCLOUD_URL="https://download.nextcloud.com/server/releases/${NEXTCLOUD_VERSION}"
INSTALL_DIR="/var/www/nextcloud"
DATA_DIR="/var/www/data"

echo "📥 Téléchargement de Nextcloud : $NEXTCLOUD_VERSION"
cd /tmp
wget -q "$NEXTCLOUD_URL"
unzip -q "$NEXTCLOUD_VERSION"
rm -rf "$INSTALL_DIR"
mv nextcloud "$INSTALL_DIR"
rm "$NEXTCLOUD_VERSION"

echo "🧹 Droits & permissions"
chown -R www-data:www-data "$INSTALL_DIR"
chown -R www-data:www-data "$DATA_DIR"

echo "🕓 Configuration cron pour www-data"
crontab -u www-data -l 2>/dev/null | grep -q "cron.php" || (
  crontab -u www-data -l 2>/dev/null; echo "*/5 * * * * php -f /var/www/nextcloud/cron.php"
) | crontab -u www-data -

echo "✅ Nextcloud installé dans $INSTALL_DIR"
echo "✅ Dossier data séparé : $DATA_DIR"
echo "✅ Cron activé pour www-data"

# Affichage des infos BDD si fichier présent
if [[ -f "$DB_INFO_FILE" ]]; then
  echo -e "\n================== 📋 RÉCAPITULATIF FINAL =================="
  cat "$DB_INFO_FILE"
  echo "⚠️ Lancer ensuite l'assistant web : https://localhost"
  echo "============================================================"
else
  echo -e "\n⚠️ Aucune information de base de données trouvée."
fi


#############
# ETAPE 7
#############

# Variables à personnaliser avant exécution :
# -------------------------------
# Redis
REDIS_HOST="localhost"
REDIS_PORT=6379
REDIS_TIMEOUT=0.0
REDIS_PASSWORD=""    # Laisser vide si pas de mot de passe

# Téléphone
PHONE_REGION="FR"

# Mail SMTP
MAIL_FROM="nextcloud"
MAIL_DOMAIN="example.com"
SMTP_MODE="smtp"
SMTP_HOST="smtp.example.com"
SMTP_PORT=587
SMTP_SECURE="tls"        # tls ou ssl
SMTP_AUTH=true
SMTP_AUTHTYPE="LOGIN"    # LOGIN, PLAIN, etc.
SMTP_USER="user@example.com"
SMTP_PASS="your_smtp_password"
# -------------------------------

pause() {
  local prompt="${1:-Suivez l’assistant web puis appuyez sur [Entrée] pour continuer…}"
  # Ouvrir explicitement le terminal contrôleur
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" </dev/tty
  else
    # fallback sur STDIN si /dev/tty indisponible
    read -rp "$prompt"
  fi
}
echo "▶️ Configuration terminée initiale terminée"
pause



##############
# POST INSTALL
##############
OCC="sudo -u www-data php /var/www/nextcloud/occ"

echo "🔧 Configuration memcache via Redis"
$OCC config:system:set memcache.local       --type=string  --value='\OC\Memcache\Redis'
$OCC config:system:set memcache.distributed --type=string  --value='\OC\Memcache\Redis'
$OCC config:system:set memcache.locking     --type=string  --value='\OC\Memcache\Redis'
$OCC config:system:set redis                --type=json    --value="{\"host\":\"${REDIS_HOST}\",\"port\":${REDIS_PORT},\"timeout\":${REDIS_TIMEOUT},\"password\":\"${REDIS_PASSWORD}\"}"

echo "🔧 Configuration default_phone_region"
$OCC config:system:set default_phone_region --type=string  --value="${PHONE_REGION}"

echo "🔧 Configuration mail SMTP"
$OCC config:system:set mail_smtpmode       --type=string  --value="${SMTP_MODE}"
$OCC config:system:set mail_from_address   --type=string  --value="${MAIL_FROM}"
$OCC config:system:set mail_domain         --type=string  --value="${MAIL_DOMAIN}"
$OCC config:system:set mail_smtphost       --type=string  --value="${SMTP_HOST}"
$OCC config:system:set mail_smtpport       --type=integer --value="${SMTP_PORT}"
$OCC config:system:set mail_smtpsecure     --type=string  --value="${SMTP_SECURE}"
$OCC config:system:set mail_smtpauth       --type=boolean --value="${SMTP_AUTH}"
$OCC config:system:set mail_smtpauthtype   --type=string  --value="${SMTP_AUTHTYPE}"
$OCC config:system:set mail_smtpname       --type=string  --value="${SMTP_USER}"
$OCC config:system:set mail_smtppassword   --type=string  --value="${SMTP_PASS}"
$OCC maintenance:repair --include-expensive
$OCC config:system:set maintenance_window_start --type=integer --value=1
echo "✅ Tous les paramètres ont été configurés."
systemctl restart apache2

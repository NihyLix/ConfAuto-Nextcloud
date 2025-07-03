#!/usr/bin/env bash
#
# ConfAuto-Nextcloud hardening ANSSI + Debian 12
#
set -euo pipefail
umask 027

# 📜 Logging complet
LOGFILE="/var/log/nextcloud_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

trap 'echo "🚨 Erreur sur la ligne $LINENO : $BASH_COMMAND"' ERR

# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# ETAPE 1 : dépôts, backports, apt-pinning
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

echo "🔍 Vérification de la version Debian"
source /etc/os-release
if [[ "$VERSION_ID" != "12" ]]; then
  echo "❌ Ce script est prévu pour Debian 12 uniquement." >&2
  exit 1
fi

echo "🧽 Sauvegarde & nettoyage des dépôts"
cp /etc/apt/sources.list{,.bak}
grep -Ev '^deb .*bookworm(-security|-updates)?.*main' /etc/apt/sources.list > /etc/apt/sources.list.tmp
cat <<EOF >> /etc/apt/sources.list.tmp
deb http://deb.debian.org/debian           bookworm         main
deb http://security.debian.org/debian-security bookworm-security main
deb http://deb.debian.org/debian           bookworm-updates main
deb http://deb.debian.org/debian           bookworm-backports main
EOF
mv /etc/apt/sources.list.tmp /etc/apt/sources.list

# Pin backports à priorité 500
cat <<EOF > /etc/apt/preferences.d/99-backports
Package: *
Pin: release a=bookworm-backports
Pin-Priority: 500
EOF

echo "🔄 Mise à jour des paquets"
apt update -y && apt upgrade -y

# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# ETAPE 2 : installation des paquets requis
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

echo "📦 Installation des paquets Nextcloud"
apt install -y \
  curl gnupg unzip \
  mariadb-server \
  apache2 \
  php8.2 php8.2-fpm libapache2-mod-php8.2 \
  php8.2-{curl,xml,gd,mbstring,zip,ldap,bcmath,gmp,intl,mysql,bz2,redis,imap,imagick} \
  libsmbclient php-memcache redis-server \
  libmagickcore-6.q16-6-extra

echo "🔍 Vérification versions :"
php -v | head -n1
apache2 -v | grep -i 'version'
mariadb --version
redis-server --version

# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# ETAPE 3 : Sécurisation MariaDB + création BDD
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

echo "⚙️ Sécurisation MariaDB"
mysql -e "
SET @@SESSION.SQL_LOG_BIN=0;
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
"

echo "🔒 Activation authent unix_socket pour root"
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket; FLUSH PRIVILEGES;"


set +o pipefail

DB_NAME="nxt_$(tr -dc '0-9' </dev/urandom | head -c 6)"
DB_USER="usrnxt_$(tr -dc '0-9' </dev/urandom | head -c 6)"
DB_PASS=$(openssl rand -base64 21)

set -o pipefail

echo "📦 Création BDD & user"
mysql -e "
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
"

# Persistance des identifiants
USER_HOME="/home/${SUDO_USER:-$(id -un)}"
mkdir -p "${USER_HOME}/nxt"
DB_INFO_FILE="${USER_HOME}/nxt/idbdd.txt"
cat > "$DB_INFO_FILE" <<EOF
================== IDENTIFIANTS NEXTCLOUD ==================
Base de données : $DB_NAME
Utilisateur      : $DB_USER
Mot de passe     : $DB_PASS
============================================================
EOF
echo "✅ Identifiants stockés dans $DB_INFO_FILE"

# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# ETAPE 4 : Optimisations MySQL & PHP + sysctl ANSSI
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

echo "⚙️ Optimisation /etc/mysql/my.cnf"
cat > /etc/mysql/my.cnf <<'EOF'
[server]
skip_name_resolve=1
innodb_buffer_pool_size=128M
innodb_buffer_pool_instances=1
innodb_flush_log_at_trx_commit=2
innodb_log_buffer_size=32M
innodb_max_dirty_pages_pct=90
# ...

[client-server]
!includedir /etc/mysql/conf.d/
!includedir /etc/mysql/mariadb.conf.d/

[client]
default-character-set=utf8mb4

[mysqld]
character_set_server=utf8mb4
collation_server=utf8mb4_general_ci
transaction_isolation=READ-COMMITTED
binlog_format=ROW
innodb_large_prefix=ON
innodb_file_format=barracuda
innodb_file_per_table=1
EOF
echo "✅ my.cnf OK"

echo "⚙️ Optimisation PHP (/etc/php/8.2/apache2/php.ini)"
PHPINI=/etc/php/8.2/apache2/php.ini
sed -i \
  -e 's/^memory_limit = .*/memory_limit = 512M/' \
  -e 's/^upload_max_filesize = .*/upload_max_filesize = 15G/' \
  -e 's/^max_execution_time = .*/max_execution_time = 360/' \
  -e 's/^output_buffering = .*/output_buffering = Off/' \
  -e 's|^;*date.timezone =.*|date.timezone = Europe/Paris|' \
  "$PHPINI"
grep -q 'opcache.enable=1' "$PHPINI" || cat >> "$PHPINI" <<'EOF'

[opcache]
opcache.enable=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.revalidate_freq=1
EOF
echo "✅ php.ini OK"

echo "⚙️ Chargement profil sysctl ANSSI"
cat > /etc/sysctl.d/60-anssi.conf <<'EOF'
# ANSSI hardening
fs.protected_symlinks=1
fs.protected_hardlinks=1
kernel.kptr_restrict=2
kernel.yama.ptrace_scope=1
# ... autres réglages ANSSI
EOF
sysctl --system

systemctl restart mysql php8.2-fpm

# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# ETAPE 5 : Apache HTTPS & VHost Nextcloud
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

echo "📁 Préparation arborescence & certificat"
rm -rf /var/www/html
mkdir -p /var/www/nextcloud /var/www/data \
         /etc/ssl/apache2/nextcloud /var/log/apache2/nextcloud
chown -R www-data:www-data /var/www

echo "🔐 Création certificat autosigné"
openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
  -keyout /etc/ssl/apache2/nextcloud/nxt.key \
  -out    /etc/ssl/apache2/nextcloud/nxt.pem \
  -subj "/C=FR/ST=Ile-de-France/O=Nextcloud/CN=localhost"

echo "🔧 Hardening Apache global"
a2enconf security
sed -i -E 's/^ServerTokens.*/ServerTokens Prod/' /etc/apache2/conf-available/security.conf
sed -i -E 's/^ServerSignature.*/ServerSignature Off/' /etc/apache2/conf-available/security.conf
echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
a2enconf servername

echo "⚙️ Création VHost Nextcloud"
cat > /etc/apache2/sites-available/nextcloud.conf <<'EOF'
<VirtualHost *:443>
    ServerName localhost
    DocumentRoot /var/www/nextcloud

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options -Indexes +FollowSymLinks

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

    # Security Headers
    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        Header always set Referrer-Policy "no-referrer"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-XSS-Protection "1; mode=block"
    </IfModule>
</VirtualHost>

EOF

a2enmod ssl rewrite headers http2
a2dissite 000-default default-ssl || true
a2ensite nextcloud.conf

systemctl restart apache2

# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# ETAPE 6 : Téléchargement & vérification Nextcloud
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

echo "📥 Récupération Nextcloud"
cd /tmp

# Récupère le dernier .zip
NEXT_VER=$(curl -s https://download.nextcloud.com/server/releases/ \
           | grep -Eo 'nextcloud-[0-9]+\.[0-9]+\.[0-9]+\.zip' \
           | sort -V | tail -n1)
echo "→ Version détectée : $NEXT_VER"
BASE="${NEXT_VER%.zip}"

# 0) Télécharger l’archive et ses checksums avec un barre de progression
for SUFFIX in .zip .zip.sha512 .zip.asc; do
  URL="https://download.nextcloud.com/server/releases/${NEXT_VER%%.zip}${SUFFIX}"
  echo -e "\n↓ Téléchargement de ${URL}"
  curl -L --fail --progress-bar -O "$URL" \
    || echo "⚠️ Échec téléchargement $SUFFIX, on continue malgré tout"
done

# 1) Importer la clé Nextcloud (silencieux si déjà fait)
gpg --keyserver keyserver.ubuntu.com --recv-keys D75899B9A724937A 2>/dev/null || true

# 2) Vérifier la signature de l’archive
if gpg --verify "${NEXT_VER}.asc" "$NEXT_VER" &>/dev/null; then
  echo "✔️ Signature PGP de l’archive OK."
else
  echo "⚠️ Échec de la signature PGP de l’archive, on continue."
fi

# 3) Extraction du hash attendu
EXPECTED=$(awk -v f="$NEXT_VER" '$2==f {print $1}' "${BASE}.zip.sha512")

# 4) Calcul du hash réel
ACTUAL=$(sha512sum "$NEXT_VER" | awk '{print $1}')

# 5) Comparaison
if [[ -n "$EXPECTED" && "$EXPECTED" == "$ACTUAL" ]]; then
  echo "✔️ Checksum SHA-512 OK."
else
  echo "❌ Checksum SHA-512 NOK (attendu: $EXPECTED, obtenu: $ACTUAL)."
fi

# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# INSTALLATION NEXTCLOUD
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

echo "🗜️ Installation"
rm -rf /var/www/nextcloud
unzip -q "$NEXT_VER"
mv nextcloud /var/www/nextcloud
chown -R www-data:www-data /var/www/nextcloud /var/www/data

# Configure cron for www-data, only if not already present
if ! crontab -u www-data -l 2>/dev/null | grep -q 'cron.php'; then
  ( 
    crontab -u www-data -l 2>/dev/null 
    echo '*/5 * * * * php -f /var/www/nextcloud/cron.php' 
  ) | crontab -u www-data -
fi


# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# Pause interactive avant POST-INSTALL
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

pause() {
  local msg="${1:-Appuyez sur Entrée pour la suite…}"
  read -rp "$msg" </dev/tty
}
echo "▶️ Étapes 1–6 terminées."
echo "$DB_INFO_FILE"
cat "$DB_INFO_FILE"

echo "Terminer l'assistance web avant de poursuivre..."
pause "🔧 Prêt pour la configuration OCC & Redis ? [Entrée]"

# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
# ETAPE 7 : POST-INSTALL OCC & config Redis, mail, maint window
# ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░

OCC="sudo -u www-data php /var/www/nextcloud/occ"

echo "🔧 Configuration memcache Redis"
$OCC config:system:set memcache.local       --type=string  --value='\OC\Memcache\Redis'
$OCC config:system:set memcache.distributed --type=string  --value='\OC\Memcache\Redis'
$OCC config:system:set memcache.locking     --type=string  --value='\OC\Memcache\Redis'
$OCC config:system:set redis                --type=json    --value="{\"host\":\"localhost\",\"port\":6379,\"timeout\":0.0,\"password\":\"\"}"

echo "🔧 Configuration région téléphone"
$OCC config:system:set default_phone_region --type=string --value="FR"

echo "🔧 Configuration SMTP mail"
$OCC config:system:set mail_smtpmode       --type=string  --value="smtp"
$OCC config:system:set mail_from_address   --type=string  --value="nextcloud"
$OCC config:system:set mail_domain         --type=string  --value="example.com"
$OCC config:system:set mail_smtphost       --type=string  --value="smtp.example.com"
$OCC config:system:set mail_smtpport       --type=integer --value=587
$OCC config:system:set mail_smtpsecure     --type=string  --value="tls"
$OCC config:system:set mail_smtpauth       --type=boolean --value=true
$OCC config:system:set mail_smtpauthtype   --type=string  --value="LOGIN"
$OCC config:system:set mail_smtpname       --type=string  --value="user@example.com"
$OCC config:system:set mail_smtppassword   --type=string  --value="your_smtp_password"
$OCC maintenance:repair --include-expensive
echo "🔧 Maintenance window (1h-5h)"
$OCC config:system:set maintenance_window_start --type=integer --value=1
echo "✅ Configuration POST-INSTALL terminée"

systemctl restart apache2 php8.2-fpm mariadb redis-server

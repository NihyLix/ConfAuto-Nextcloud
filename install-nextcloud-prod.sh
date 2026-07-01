#!/usr/bin/env bash
#
# Installation Nextcloud production interne
# Debian 12 + Apache php-fpm + MariaDB + Redis
# Reverse proxy attendu : Traefik en frontal HTTPS
#
# Usage :
#   sudo bash install-nextcloud-prod.sh ./nextcloud-install.var
#
set -Eeuo pipefail
umask 027

SCRIPT_VERSION="1.0.0"
DEFAULT_VAR_FILE="./nextcloud-install.var"
VAR_FILE="${1:-$DEFAULT_VAR_FILE}"
LOG_FILE="/var/log/nextcloud-install.log"
SECRETS_FILE="/root/nextcloud-install-secrets.env"
INSTALL_STATE_DIR="/etc/nextcloud-install"
TMP_DIR="/tmp/nextcloud-install"

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "ERROR line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[$(date +'%F %T')] $*" >&2
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "ce script doit être lancé en root."
}

require_var_file() {
  [[ -f "$VAR_FILE" ]] || die "fichier de variables introuvable : $VAR_FILE"
  # shellcheck source=/dev/null
  source "$VAR_FILE"
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "variable obligatoire manquante : $name"
}

bool_is_true() {
  [[ "${1:-false}" == "true" || "${1:-false}" == "1" || "${1:-false}" == "yes" ]]
}

valid_sql_identifier() {
  [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

safe_mkdir() {
  local path="$1"
  local owner="$2"
  local mode="$3"
  mkdir -p "$path"
  chown "$owner" "$path"
  chmod "$mode" "$path"
}

set_default_vars() {
  : "${DEBIAN_VERSION_REQUIRED:=12}"
  : "${NEXTCLOUD_VERSION:=latest}"
  : "${PHP_VERSION:=8.2}"
  : "${TIMEZONE:=Europe/Paris}"

  : "${NC_WEB_DIR:=/var/www/nextcloud}"
  : "${NC_DATA_DIR:=/var/www/data}"
  : "${NC_ADMIN_USER:=ncadmin}"
  : "${NC_ADMIN_PASS:=}"

  : "${NC_DB_NAME:=nextcloud}"
  : "${NC_DB_USER:=nextcloud}"
  : "${NC_DB_PASS:=}"
  : "${DB_INNODB_BUFFER_POOL_SIZE:=1G}"

  : "${APACHE_BACKEND_PORT:=443}"
  : "${APACHE_SSL_DIR:=/etc/ssl/apache2/nextcloud}"
  : "${APACHE_LOG_DIR:=/var/log/apache2/nextcloud}"
  : "${ENABLE_HSTS:=true}"

  : "${PHP_MEMORY_LIMIT:=512M}"
  : "${PHP_UPLOAD_MAX_FILESIZE:=15G}"
  : "${PHP_POST_MAX_SIZE:=15G}"
  : "${PHP_MAX_EXECUTION_TIME:=360}"
  : "${PHP_MAX_INPUT_TIME:=360}"

  : "${DEFAULT_PHONE_REGION:=FR}"
  : "${MAINTENANCE_WINDOW_START:=1}"

  : "${SMTP_ENABLE:=false}"
  : "${SMTP_HOST:=}"
  : "${SMTP_PORT:=587}"
  : "${SMTP_SECURE:=tls}"
  : "${SMTP_AUTH:=true}"
  : "${SMTP_AUTHTYPE:=LOGIN}"
  : "${SMTP_FROM_ADDRESS:=nextcloud}"
  : "${SMTP_DOMAIN:=example.local}"
  : "${SMTP_USER:=}"
  : "${SMTP_PASS:=}"

  : "${BACKUP_DIR:=/var/backups/nextcloud}"
  : "${BACKUP_RETENTION_DAYS:=14}"
  : "${ENABLE_LOCAL_DB_BACKUP_CRON:=false}"
  : "${LOCAL_DB_BACKUP_CRON_TIME:=10 2 * * *}"

  : "${FORCE_REINSTALL:=false}"
}

preflight() {
  require_root
  require_var_file
  set_default_vars

  require_var NC_FQDN
  require_var TRAEFIK_PROXY_IPS

  valid_sql_identifier "$NC_DB_NAME" || die "NC_DB_NAME invalide : utiliser uniquement lettres, chiffres et underscore."
  valid_sql_identifier "$NC_DB_USER" || die "NC_DB_USER invalide : utiliser uniquement lettres, chiffres et underscore."

  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "OS non supporté : Debian requis."
  [[ "${VERSION_ID:-}" == "$DEBIAN_VERSION_REQUIRED" ]] || die "Debian $DEBIAN_VERSION_REQUIRED requis. Version détectée : ${VERSION_ID:-inconnue}."

  if [[ -f "$NC_WEB_DIR/config/config.php" ]] && ! bool_is_true "$FORCE_REINSTALL"; then
    die "Nextcloud semble déjà installé dans $NC_WEB_DIR. Refus de continuer sans FORCE_REINSTALL=true."
  fi

  if bool_is_true "$SMTP_ENABLE"; then
    require_var SMTP_HOST
    require_var SMTP_FROM_ADDRESS
    require_var SMTP_DOMAIN
    if bool_is_true "$SMTP_AUTH"; then
      require_var SMTP_USER
      require_var SMTP_PASS
    fi
  fi

  if [[ -z "$NC_ADMIN_PASS" ]]; then
    NC_ADMIN_PASS="$(openssl rand -base64 30 | tr -d '\n')"
  fi

  if [[ -z "$NC_DB_PASS" ]]; then
    NC_DB_PASS="$(openssl rand -base64 36 | tr -d '\n')"
  fi
}

persist_config_and_secrets() {
  log "Persistance de la configuration et des secrets"
  mkdir -p "$INSTALL_STATE_DIR"
  chmod 750 "$INSTALL_STATE_DIR"
  cp "$VAR_FILE" "$INSTALL_STATE_DIR/nextcloud-install.var"
  chmod 640 "$INSTALL_STATE_DIR/nextcloud-install.var"

  cat > "$SECRETS_FILE" <<EOF_SECRETS
# Secrets générés pendant l'installation Nextcloud
# Permissions attendues : root:root 600
NC_ADMIN_USER='$NC_ADMIN_USER'
NC_ADMIN_PASS='$NC_ADMIN_PASS'
NC_DB_NAME='$NC_DB_NAME'
NC_DB_USER='$NC_DB_USER'
NC_DB_PASS='$NC_DB_PASS'
NC_WEB_DIR='$NC_WEB_DIR'
NC_DATA_DIR='$NC_DATA_DIR'
BACKUP_DIR='$BACKUP_DIR'
BACKUP_RETENTION_DAYS='$BACKUP_RETENTION_DAYS'
EOF_SECRETS
  chown root:root "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
}

configure_apt() {
  log "Mise à jour APT"
  apt-get update
}

install_packages() {
  log "Installation des paquets système"

  local php="php${PHP_VERSION}"
  local packages=(
    ca-certificates curl gnupg dirmngr unzip rsync acl openssl cron logrotate
    apache2 mariadb-server redis-server imagemagick ffmpeg bzip2
    "${php}" "${php}-cli" "${php}-fpm" "${php}-common" "${php}-curl" "${php}-xml"
    "${php}-gd" "${php}-mbstring" "${php}-zip" "${php}-ldap" "${php}-bcmath"
    "${php}-gmp" "${php}-intl" "${php}-mysql" "${php}-bz2" "${php}-redis"
    "${php}-imap" "${php}-imagick" "${php}-apcu" "${php}-opcache"
    libmagickcore-6.q16-6-extra
  )

  apt-get install -y "${packages[@]}"
}

configure_sysctl() {
  log "Application d'un durcissement sysctl minimal"
  cat > /etc/sysctl.d/60-nextcloud-hardening.conf <<'EOF_SYSCTL'
# Durcissement système minimal pour serveur applicatif interne
fs.protected_symlinks=1
fs.protected_hardlinks=1
fs.protected_fifos=2
fs.protected_regular=2
kernel.kptr_restrict=2
kernel.yama.ptrace_scope=1
kernel.dmesg_restrict=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
EOF_SYSCTL
  sysctl --system >/dev/null
}

configure_mariadb() {
  log "Configuration MariaDB"

  cat > /etc/mysql/mariadb.conf.d/60-nextcloud.cnf <<EOF_MYSQL
[mysqld]
transaction_isolation=READ-COMMITTED
binlog_format=ROW
innodb_file_per_table=1
innodb_buffer_pool_size=${DB_INNODB_BUFFER_POOL_SIZE}
innodb_flush_log_at_trx_commit=2
innodb_log_buffer_size=64M
skip_name_resolve=1
character_set_server=utf8mb4
collation_server=utf8mb4_general_ci
EOF_MYSQL

  systemctl enable --now mariadb
  systemctl restart mariadb

  mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket; FLUSH PRIVILEGES;" || true

  mariadb <<EOF_SQL
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS \`${NC_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';
ALTER USER '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${NC_DB_NAME}\`.* TO '${NC_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF_SQL
}

configure_php() {
  log "Configuration PHP-FPM"

  local php_conf_dir="/etc/php/${PHP_VERSION}"
  [[ -d "$php_conf_dir" ]] || die "répertoire PHP introuvable : $php_conf_dir"

  for sapi in fpm cli; do
    cat > "${php_conf_dir}/${sapi}/conf.d/90-nextcloud.ini" <<EOF_PHP
memory_limit=${PHP_MEMORY_LIMIT}
upload_max_filesize=${PHP_UPLOAD_MAX_FILESIZE}
post_max_size=${PHP_POST_MAX_SIZE}
max_execution_time=${PHP_MAX_EXECUTION_TIME}
max_input_time=${PHP_MAX_INPUT_TIME}
date.timezone=${TIMEZONE}
output_buffering=Off
apc.enable_cli=1

opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.memory_consumption=256
opcache.save_comments=1
opcache.revalidate_freq=60
EOF_PHP
  done

  systemctl enable --now "php${PHP_VERSION}-fpm"
  systemctl restart "php${PHP_VERSION}-fpm"
}

configure_redis() {
  log "Configuration Redis socket local"

  sed -ri 's|^#?\s*unixsocket\s+.*|unixsocket /run/redis/redis-server.sock|' /etc/redis/redis.conf
  sed -ri 's|^#?\s*unixsocketperm\s+.*|unixsocketperm 770|' /etc/redis/redis.conf
  sed -ri 's|^#?\s*bind\s+.*|bind 127.0.0.1 ::1|' /etc/redis/redis.conf
  sed -ri 's|^#?\s*protected-mode\s+.*|protected-mode yes|' /etc/redis/redis.conf

  usermod -aG redis www-data
  systemctl enable --now redis-server
  systemctl restart redis-server
}

configure_apache() {
  log "Configuration Apache backend Traefik"

  safe_mkdir "$APACHE_SSL_DIR" root:root 750
  safe_mkdir "$APACHE_LOG_DIR" root:adm 750

  local cert="${APACHE_SSL_DIR}/nextcloud.pem"
  local key="${APACHE_SSL_DIR}/nextcloud.key"

  if [[ ! -f "$cert" || ! -f "$key" ]]; then
    openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
      -keyout "$key" \
      -out "$cert" \
      -subj "/C=FR/O=Nextcloud Internal/CN=${NC_FQDN}"
    chmod 640 "$key"
    chmod 644 "$cert"
  fi

  if ! grep -Eq "^Listen ${APACHE_BACKEND_PORT}$" /etc/apache2/ports.conf; then
    echo "Listen ${APACHE_BACKEND_PORT}" >> /etc/apache2/ports.conf
  fi

  cat > /etc/apache2/conf-available/nextcloud-hardening.conf <<'EOF_APACHE_HARDENING'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
EOF_APACHE_HARDENING

  local remoteip_lines=""
  local proxy_ip
  for proxy_ip in $TRAEFIK_PROXY_IPS; do
    remoteip_lines+="    RemoteIPTrustedProxy ${proxy_ip}"$'\n'
  done

  local hsts_line=""
  if bool_is_true "$ENABLE_HSTS"; then
    hsts_line='        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"'
  fi

  cat > /etc/apache2/sites-available/nextcloud.conf <<EOF_VHOST
<VirtualHost *:${APACHE_BACKEND_PORT}>
    ServerName ${NC_FQDN}
    DocumentRoot ${NC_WEB_DIR}
    Protocols h2 http/1.1

    SSLEngine on
    SSLCertificateFile ${cert}
    SSLCertificateKeyFile ${key}

    RemoteIPHeader X-Forwarded-For
${remoteip_lines}

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
    LogLevel warn

    <Directory ${NC_WEB_DIR}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VERSION}-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    <IfModule mod_headers.c>
        Header always set Referrer-Policy "no-referrer"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-XSS-Protection "1; mode=block"
${hsts_line}
    </IfModule>

    RewriteEngine On
    RewriteRule ^/\.well-known/carddav /remote.php/dav/ [R=301,L]
    RewriteRule ^/\.well-known/caldav /remote.php/dav/ [R=301,L]
</VirtualHost>
EOF_VHOST

  a2enmod ssl rewrite headers http2 proxy proxy_fcgi setenvif env remoteip dir mime >/dev/null
  a2enconf nextcloud-hardening >/dev/null
  a2dissite 000-default default-ssl >/dev/null 2>&1 || true
  a2ensite nextcloud.conf >/dev/null
  a2dismod "php${PHP_VERSION}" >/dev/null 2>&1 || true

  apache2ctl configtest
  systemctl enable --now apache2
  systemctl restart apache2
}

detect_nextcloud_archive() {
  local archive

  if [[ "$NEXTCLOUD_VERSION" == "latest" ]]; then
    log "Détection de la dernière version Nextcloud disponible"
    archive="$(curl -fsSL https://download.nextcloud.com/server/releases/ \
      | grep -Eo 'nextcloud-[0-9]+\.[0-9]+\.[0-9]+\.zip' \
      | sort -V \
      | tail -n1)"
    [[ -n "$archive" ]] || die "impossible de détecter la dernière version Nextcloud."
  else
    archive="nextcloud-${NEXTCLOUD_VERSION}.zip"
  fi

  echo "$archive"
}

download_and_verify_nextcloud() {
  log "Téléchargement et vérification Nextcloud"

  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR"

  local archive="$1"
  local base="${archive%.zip}"
  local suffix url

  for suffix in .zip .zip.sha512 .zip.asc; do
    url="https://download.nextcloud.com/server/releases/${base}${suffix}"
    log "Téléchargement : $url"
    curl -L --fail --show-error --progress-bar -O "$url" || die "échec téléchargement : $url"
  done

  local gpg_home="/root/.gnupg-nextcloud"
  mkdir -p "$gpg_home"
  chmod 700 "$gpg_home"

  # Clé de signature Nextcloud server releases.
  gpg --homedir "$gpg_home" --batch --keyserver keyserver.ubuntu.com --recv-keys D75899B9A724937A || \
    die "impossible d'importer la clé PGP Nextcloud."

  gpg --homedir "$gpg_home" --batch --verify "${archive}.asc" "$archive" || \
    die "signature PGP Nextcloud invalide."

  if grep -q "$archive" "${archive}.sha512"; then
    sha512sum -c "${archive}.sha512" || die "checksum SHA-512 invalide."
  else
    local expected
    expected="$(awk '{print $1}' "${archive}.sha512" | head -n1)"
    [[ -n "$expected" ]] || die "checksum attendu vide."
    echo "${expected}  ${archive}" | sha512sum -c - || die "checksum SHA-512 invalide."
  fi

  log "Archive Nextcloud validée : $archive"
}

install_nextcloud_files() {
  log "Installation des fichiers Nextcloud"

  local archive="$1"
  local extract_dir
  extract_dir="$(mktemp -d)"

  if [[ -d "$NC_WEB_DIR" ]] && [[ -n "$(find "$NC_WEB_DIR" -mindepth 1 -maxdepth 1 2>/dev/null || true)" ]] && ! bool_is_true "$FORCE_REINSTALL"; then
    die "$NC_WEB_DIR n'est pas vide. Refus de continuer sans FORCE_REINSTALL=true."
  fi

  if bool_is_true "$FORCE_REINSTALL"; then
    rm -rf "$NC_WEB_DIR"
  fi

  safe_mkdir "$NC_WEB_DIR" www-data:www-data 750
  safe_mkdir "$NC_DATA_DIR" www-data:www-data 750

  unzip -q "${TMP_DIR}/${archive}" -d "$extract_dir"
  rsync -a --delete "${extract_dir}/nextcloud/" "$NC_WEB_DIR/"
  chown -R www-data:www-data "$NC_WEB_DIR" "$NC_DATA_DIR"

  rm -rf "$extract_dir"
}

occ() {
  runuser -u www-data -- php "${NC_WEB_DIR}/occ" "$@"
}

install_nextcloud_app() {
  log "Installation applicative Nextcloud"

  occ maintenance:install \
    --database "mysql" \
    --database-host "localhost" \
    --database-name "$NC_DB_NAME" \
    --database-user "$NC_DB_USER" \
    --database-pass "$NC_DB_PASS" \
    --admin-user "$NC_ADMIN_USER" \
    --admin-pass "$NC_ADMIN_PASS" \
    --data-dir "$NC_DATA_DIR"

  occ config:system:set trusted_domains 0 --type=string --value="$NC_FQDN"
  occ config:system:set overwritehost --type=string --value="$NC_FQDN"
  occ config:system:set overwriteprotocol --type=string --value="https"
  occ config:system:set overwrite.cli.url --type=string --value="https://${NC_FQDN}"
  occ config:system:set forwarded_for_headers 0 --type=string --value="HTTP_X_FORWARDED_FOR"

  local idx=0
  local proxy_ip
  for proxy_ip in $TRAEFIK_PROXY_IPS; do
    occ config:system:set trusted_proxies "$idx" --type=string --value="$proxy_ip"
    idx=$((idx + 1))
  done

  occ config:system:set memcache.local --type=string --value='\OC\Memcache\APCu'
  occ config:system:set memcache.distributed --type=string --value='\OC\Memcache\Redis'
  occ config:system:set memcache.locking --type=string --value='\OC\Memcache\Redis'
  occ config:system:set redis --type=json --value='{"host":"/run/redis/redis-server.sock","port":0,"timeout":0.0}'
  occ config:system:set default_phone_region --type=string --value="$DEFAULT_PHONE_REGION"
  occ config:system:set maintenance_window_start --type=integer --value="$MAINTENANCE_WINDOW_START"
  occ background:cron

  occ config:system:set htaccess.RewriteBase --type=string --value="/"
  occ maintenance:update:htaccess

  if bool_is_true "$SMTP_ENABLE"; then
    log "Configuration SMTP Nextcloud"
    occ config:system:set mail_smtpmode --type=string --value="smtp"
    occ config:system:set mail_from_address --type=string --value="$SMTP_FROM_ADDRESS"
    occ config:system:set mail_domain --type=string --value="$SMTP_DOMAIN"
    occ config:system:set mail_smtphost --type=string --value="$SMTP_HOST"
    occ config:system:set mail_smtpport --type=integer --value="$SMTP_PORT"
    occ config:system:set mail_smtpsecure --type=string --value="$SMTP_SECURE"
    occ config:system:set mail_smtpauth --type=boolean --value="$SMTP_AUTH"
    if bool_is_true "$SMTP_AUTH"; then
      occ config:system:set mail_smtpauthtype --type=string --value="$SMTP_AUTHTYPE"
      occ config:system:set mail_smtpname --type=string --value="$SMTP_USER"
      occ config:system:set mail_smtppassword --type=string --value="$SMTP_PASS"
    fi
  fi

  occ maintenance:repair --include-expensive
}

configure_cron() {
  log "Configuration cron Nextcloud"

  cat > /etc/cron.d/nextcloud <<EOF_CRON
# Cron applicatif Nextcloud
*/5 * * * * www-data php -f ${NC_WEB_DIR}/cron.php
EOF_CRON
  chmod 644 /etc/cron.d/nextcloud
  systemctl enable --now cron
}

create_backup_helper() {
  log "Création du script de sauvegarde applicative"

  safe_mkdir "$BACKUP_DIR" root:root 750

  cat > /usr/local/sbin/nextcloud-app-backup.sh <<'EOF_BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

STATE_VAR_FILE="/etc/nextcloud-install/nextcloud-install.var"
SECRETS_FILE="/root/nextcloud-install-secrets.env"

[[ -f "$STATE_VAR_FILE" ]] || { echo "Fichier manquant : $STATE_VAR_FILE" >&2; exit 1; }
[[ -f "$SECRETS_FILE" ]] || { echo "Fichier manquant : $SECRETS_FILE" >&2; exit 1; }

# shellcheck source=/dev/null
source "$STATE_VAR_FILE"
# shellcheck source=/dev/null
source "$SECRETS_FILE"

: "${BACKUP_DIR:=/var/backups/nextcloud}"
: "${BACKUP_RETENTION_DAYS:=14}"

mkdir -p "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"

occ() {
  runuser -u www-data -- php "${NC_WEB_DIR}/occ" "$@"
}

stamp="$(date +'%Y%m%d-%H%M%S')"
dump_file="${BACKUP_DIR}/nextcloud-db-${stamp}.sql.gz"

cleanup() {
  occ maintenance:mode --off >/dev/null 2>&1 || true
}
trap cleanup EXIT

occ maintenance:mode --on
mariadb-dump --single-transaction --routines --triggers --default-character-set=utf8mb4 "$NC_DB_NAME" | gzip -9 > "$dump_file"
chmod 640 "$dump_file"
occ maintenance:mode --off
trap - EXIT

find "$BACKUP_DIR" -type f -name 'nextcloud-db-*.sql.gz' -mtime "+${BACKUP_RETENTION_DAYS}" -delete

echo "$dump_file"
EOF_BACKUP

  chown root:root /usr/local/sbin/nextcloud-app-backup.sh
  chmod 750 /usr/local/sbin/nextcloud-app-backup.sh

  if bool_is_true "$ENABLE_LOCAL_DB_BACKUP_CRON"; then
    cat > /etc/cron.d/nextcloud-db-backup <<EOF_BACKUP_CRON
# Dump MariaDB applicatif avant sauvegarde VM/PBS si souhaité
${LOCAL_DB_BACKUP_CRON_TIME} root /usr/local/sbin/nextcloud-app-backup.sh >/var/log/nextcloud-db-backup.log 2>&1
EOF_BACKUP_CRON
    chmod 644 /etc/cron.d/nextcloud-db-backup
  fi
}

configure_logrotate() {
  log "Configuration logrotate"

  cat > /etc/logrotate.d/nextcloud-apache <<EOF_LOGROTATE
${APACHE_LOG_DIR}/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl reload apache2 >/dev/null 2>&1 || true
    endscript
}
EOF_LOGROTATE
}

final_checks() {
  log "Contrôles finaux"

  php -v | head -n1
  apache2 -v | head -n1
  mariadb --version
  redis-server --version

  occ status
  occ config:system:get trusted_domains
  occ config:system:get trusted_proxies

  systemctl restart "php${PHP_VERSION}-fpm" apache2 mariadb redis-server cron

  log "Installation terminée. Secrets root-only : $SECRETS_FILE"
  log "Backend Apache : https://${NC_FQDN}:${APACHE_BACKEND_PORT}"
  log "Configurer Traefik vers cette VM et filtrer tout accès direct hors Traefik."
}

main() {
  log "Installation Nextcloud interne v${SCRIPT_VERSION}"
  preflight
  persist_config_and_secrets
  configure_apt
  install_packages
  configure_sysctl
  configure_mariadb
  configure_php
  configure_redis
  configure_apache

  local archive
  archive="$(detect_nextcloud_archive)"
  download_and_verify_nextcloud "$archive"
  install_nextcloud_files "$archive"
  install_nextcloud_app
  configure_cron
  create_backup_helper
  configure_logrotate
  final_checks
}

main "$@"

#!/bin/bash
# Runs as root: sets up MariaDB + persistence, then hands off to the upstream
# LimeSurvey entrypoint as www-data.
set -euo pipefail

DATA_DIR="${OPENHOST_APP_DATA_DIR:-/data/app_data/limesurvey}"
MYSQL_DATA="$DATA_DIR/mysql"
SECRETS_DIR="$DATA_DIR/secrets"
SOCK=/run/mysqld/mysqld.sock
WEBROOT=/var/www/html

# --- Secrets: generated once, persisted across restarts ---
mkdir -p "$SECRETS_DIR"
gen_secret() {
    # od reads exactly 16 bytes and exits — no SIGPIPE under pipefail (unlike
    # `tr </dev/urandom | head`).
    [ -s "$1" ] || od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$1"
}
gen_secret "$SECRETS_DIR/db_password"
gen_secret "$SECRETS_DIR/admin_password"
# www-data must read these (the upstream entrypoint runs as www-data and loads
# them via the *_FILE env vars).
chown -R root:www-data "$SECRETS_DIR"
chmod 750 "$SECRETS_DIR"
chmod 640 "$SECRETS_DIR"/*

# --- MariaDB on persistent storage ---
mkdir -p "$MYSQL_DATA" /run/mysqld
chown -R mysql:mysql "$MYSQL_DATA" /run/mysqld

if [ ! -d "$MYSQL_DATA/mysql" ]; then
    echo "Info: initializing MariaDB data directory"
    mariadb-install-db --user=mysql --datadir="$MYSQL_DATA" > /dev/null
fi

mariadbd --user=mysql --datadir="$MYSQL_DATA" \
    --bind-address=127.0.0.1 --port=3306 --socket="$SOCK" &
MARIADB_PID=$!

for _ in $(seq 1 60); do
    mariadb-admin --socket="$SOCK" ping > /dev/null 2>&1 && break
    sleep 1
done
mariadb-admin --socket="$SOCK" ping > /dev/null

DB_PASS="$(cat "$SECRETS_DIR/db_password")"
mariadb --socket="$SOCK" <<SQL
CREATE DATABASE IF NOT EXISTS limesurvey;
CREATE USER IF NOT EXISTS 'limesurvey'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
ALTER USER 'limesurvey'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON limesurvey.* TO 'limesurvey'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# --- Persist LimeSurvey state ---
# upload/ holds all user content (survey files, themes, plugins). First boot
# seeds it from the image's base content, then the webroot path is a symlink.
if [ ! -d "$DATA_DIR/upload" ]; then
    cp -a "$WEBROOT/upload" "$DATA_DIR/upload"
fi
rm -rf "$WEBROOT/upload"
ln -s "$DATA_DIR/upload" "$WEBROOT/upload"
chown -R www-data:www-data "$DATA_DIR/upload"

# security.php holds the data-encryption keys LimeSurvey generates on first
# use — losing it makes encrypted responses unreadable. Symlink it into the
# data dir (dangling until LimeSurvey writes it, which creates the target).
mkdir -p "$DATA_DIR/config"
chown www-data:www-data "$DATA_DIR/config"
ln -sfn "$DATA_DIR/config/security.php" "$WEBROOT/application/config/security.php"

# config.php is derived entirely from env + persisted secrets; remove any copy
# from a previous boot so the upstream entrypoint regenerates it (keeps the
# public URL correct across app renames).
rm -f "$WEBROOT/application/config/config.php"

# --- Env for the upstream entrypoint (config generation + auto-install) ---
EXTERNAL_HOST="${OPENHOST_APP_NAME:-limesurvey}.${OPENHOST_ZONE_DOMAIN:-localhost}"
EXTERNAL_URL="https://$EXTERNAL_HOST"

export DB_TYPE=mysql DB_HOST=127.0.0.1 DB_PORT=3306
export DB_NAME=limesurvey DB_USERNAME=limesurvey
export DB_PASSWORD_FILE="$SECRETS_DIR/db_password"
export DB_MYSQL_ENGINE=InnoDB
export ADMIN_USER="${OPENHOST_OWNER_USERNAME:-admin}"
export ADMIN_NAME="${OPENHOST_OWNER_USERNAME:-admin}"
export ADMIN_EMAIL="${ADMIN_EMAIL:-${OPENHOST_OWNER_USERNAME:-owner}@${OPENHOST_ZONE_DOMAIN:-localhost}}"
export ADMIN_PASSWORD_FILE="$SECRETS_DIR/admin_password"
export PUBLIC_URL="$EXTERNAL_URL"
export HOST_INFO="$EXTERNAL_URL"
export LISTEN_PORT=8080

# --- Owner SSO: map the router's owner header to a server variable for the
# Authwebserver plugin. The router strips X-OpenHost-Is-Owner from client
# requests (it is the sole authority), so this cannot be spoofed.
cat > /etc/apache2/conf-enabled/openhost-sso.conf <<EOF
SetEnvIf X-OpenHost-Is-Owner "^true$" OPENHOST_SSO_USER=$ADMIN_USER

# Send the owner from the app root to the admin panel (SSO logs them in);
# anonymous respondents still get the public survey pages. The target must be
# the absolute external URL: the router forwards with an internal Host header
# and does not rewrite Location, so a path-only target would redirect the
# browser to 127.0.0.1.
RewriteEngine On
RewriteCond %{HTTP:X-OpenHost-Is-Owner} =true
RewriteRule ^/$ $EXTERNAL_URL/index.php/admin [R=302,L]

# LimeSurvey's REST API (used by the new survey editor) looks up
# getallheaders()['Authorization'] case-sensitively, but the router forwards
# header names lowercase, so the editor's bearer token was invisible and every
# /rest call 401'd. Re-add the header with canonical casing.
SetEnvIf Authorization "(.+)" OPENHOST_RAW_AUTH=\$1
RequestHeader unset Authorization
RequestHeader set Authorization "%{OPENHOST_RAW_AUTH}e" env=OPENHOST_RAW_AUTH

# Make PHP see the external https origin. Some editor code builds absolute URLs
# from \$_SERVER['HTTPS'] + HTTP_HOST instead of hostInfo, which behind the
# router are the unreachable internal 127.0.0.1:<port> over http.
RequestHeader set Host "$EXTERNAL_HOST"
SetEnv HTTPS on

# Fix the editor's broken /admin home link: /admin is a real directory, so
# mod_dir 301s it to /admin/ using the internal host, sending the browser to
# http://127.0.0.1:<port>/admin/. Serve directories via their DirectoryIndex
# instead of redirecting (Indexes off so this can't expose a listing).
<Directory /var/www/html>
    DirectorySlash Off
    Options -Indexes
</Directory>
EOF

# Provision LimeSurvey settings once the schema exists (the installer runs
# after apache starts, so poll in the background):
# - Activate + configure the Authwebserver plugin for owner SSO.
#   is_default=false keeps password login as fallback when the header is absent.
# - Seed the site contact (shown on public pages) in place of LimeSurvey's
#   "Your Name (your-email@example.net)" placeholder. Only missing rows and
#   untouched placeholders are written, so UI edits stick.
provision_limesurvey() {
    for _ in $(seq 1 300); do
        if mariadb --socket="$SOCK" limesurvey -N -e "SELECT 1 FROM lime_plugins LIMIT 1" > /dev/null 2>&1; then
            mariadb --socket="$SOCK" limesurvey <<'SQL'
INSERT INTO lime_plugins (name, plugin_type, active, priority)
SELECT 'Authwebserver', 'core', 1, 0
WHERE NOT EXISTS (SELECT 1 FROM lime_plugins WHERE name = 'Authwebserver');
UPDATE lime_plugins SET active = 1 WHERE name = 'Authwebserver';
DELETE s FROM lime_plugin_settings s
    JOIN lime_plugins p ON s.plugin_id = p.id
    WHERE p.name = 'Authwebserver' AND s.`key` IN ('serverkey', 'is_default');
INSERT INTO lime_plugin_settings (plugin_id, `key`, value)
    SELECT id, 'serverkey', '"OPENHOST_SSO_USER"' FROM lime_plugins WHERE name = 'Authwebserver';
INSERT INTO lime_plugin_settings (plugin_id, `key`, value)
    SELECT id, 'is_default', 'false' FROM lime_plugins WHERE name = 'Authwebserver';
SQL
            mariadb --socket="$SOCK" limesurvey <<SQL
INSERT INTO lime_settings_global (stg_name, stg_value)
SELECT 'siteadminname', '$ADMIN_USER'
WHERE NOT EXISTS (SELECT 1 FROM lime_settings_global WHERE stg_name = 'siteadminname');
UPDATE lime_settings_global SET stg_value = '$ADMIN_USER'
    WHERE stg_name = 'siteadminname' AND stg_value = 'Your Name';
INSERT INTO lime_settings_global (stg_name, stg_value)
SELECT 'siteadminemail', '$ADMIN_EMAIL'
WHERE NOT EXISTS (SELECT 1 FROM lime_settings_global WHERE stg_name = 'siteadminemail');
UPDATE lime_settings_global SET stg_value = '$ADMIN_EMAIL'
    WHERE stg_name = 'siteadminemail' AND stg_value = 'your-email@example.net';
INSERT INTO lime_settings_global (stg_name, stg_value)
SELECT 'siteadminbounce', '$ADMIN_EMAIL'
WHERE NOT EXISTS (SELECT 1 FROM lime_settings_global WHERE stg_name = 'siteadminbounce');
UPDATE lime_settings_global SET stg_value = '$ADMIN_EMAIL'
    WHERE stg_name = 'siteadminbounce' AND stg_value = 'your-email@example.net';
SQL
            echo "Info: LimeSurvey provisioned (owner SSO + site contact)"
            return 0
        fi
        sleep 2
    done
    echo "Warning: timed out waiting for LimeSurvey schema; SSO/site contact not provisioned" >&2
}
provision_limesurvey &

setpriv --reuid=www-data --regid=www-data --init-groups \
    /usr/local/bin/entrypoint.sh "$@" &
APP_PID=$!

shutdown() {
    kill -TERM "$APP_PID" 2> /dev/null || true
    wait "$APP_PID" 2> /dev/null || true
    mariadb-admin --socket="$SOCK" shutdown 2> /dev/null || true
    wait "$MARIADB_PID" 2> /dev/null || true
}
trap 'shutdown; exit 0' TERM INT

# If either apache or mariadb dies, take the whole container down.
RC=0
wait -n "$APP_PID" "$MARIADB_PID" || RC=$?
shutdown
exit "$RC"

#!/usr/bin/env bash
# ============================================================================
# 30-setup-mysql.sh — crea la base y el usuario MySQL para PvPGN
# Correr con sudo (usa el auth_socket de root de MySQL en Ubuntu). Idempotente.
#
# Las TABLAS no se crean aca: PvPGN las crea solo en el primer arranque a
# partir de etc/pvpgn/sql_DB_layout.conf (comportamiento documentado en ese
# mismo archivo: "the server will create the tables ... don't forget to
# create the DB yourself").
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"

log() { printf '[setup-mysql] %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Correr con sudo (necesita el socket de root de MySQL)." >&2
    exit 1
fi
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Falta ${ENV_FILE}. Copia .env.example a .env y completalo." >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

: "${WC3_DB_NAME:?falta WC3_DB_NAME en .env}"
: "${WC3_DB_USER:?falta WC3_DB_USER en .env}"
: "${WC3_DB_PASS:?falta WC3_DB_PASS en .env}"
if [[ "${WC3_DB_PASS}" == "CAMBIAME" ]]; then
    echo "WC3_DB_PASS sigue en CAMBIAME. Genera una con: openssl rand -base64 24" >&2
    exit 1
fi

systemctl enable --now mysql

log "creando base ${WC3_DB_NAME} y usuario ${WC3_DB_USER} (si no existen)"
mysql --user=root <<SQL
CREATE DATABASE IF NOT EXISTS \`${WC3_DB_NAME}\`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WC3_DB_USER}'@'localhost'
    IDENTIFIED BY '${WC3_DB_PASS}';
ALTER USER '${WC3_DB_USER}'@'localhost' IDENTIFIED BY '${WC3_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${WC3_DB_NAME}\`.* TO '${WC3_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

log "verificando acceso con el usuario ${WC3_DB_USER}"
mysql --user="${WC3_DB_USER}" --password="${WC3_DB_PASS}" \
      --host=127.0.0.1 --execute="USE \`${WC3_DB_NAME}\`; SELECT 1;" >/dev/null
log "OK. Proximo paso: install/40-render-configs.sh"

#!/usr/bin/env bash
# ============================================================================
# backup.sh — dump de MySQL + configs a un tar fechado en /opt/wc3/backups
# Correr con sudo en el VPS (necesita leer las configs y el socket de MySQL).
#
#   sudo ./scripts/backup.sh
#
# Guarda: dump de la base de PvPGN, etc/pvpgn completo, aura.cfg de cada
# instancia y el registry de mapas. NO incluye los .w3x (pesan y se
# reconstruyen desde el map pack) ni los MPQ del juego.
# Retencion: se conservan los ultimos 14 backups.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"
BACKUP_ROOT=/opt/wc3/backups
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log() { printf '[backup] %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Correr con sudo." >&2
    exit 1
fi
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Falta ${ENV_FILE} (necesito las credenciales de la base)." >&2
    exit 1
fi
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

install -d "${WORK}/dump" "${WORK}/configs"

log "dump de MySQL (${WC3_DB_NAME})"
mysqldump --user="${WC3_DB_USER}" --password="${WC3_DB_PASS}" \
    --host="${WC3_DB_HOST}" --single-transaction --routines \
    "${WC3_DB_NAME}" > "${WORK}/dump/${WC3_DB_NAME}.sql"

log "copiando configs"
cp -a /opt/wc3/pvpgn/etc/pvpgn "${WORK}/configs/pvpgn"
if compgen -G '/opt/wc3/hostbot/instances/*/aura.cfg' >/dev/null; then
    for cfg in /opt/wc3/hostbot/instances/*/aura.cfg; do
        n="$(basename "$(dirname "${cfg}")")"
        install -D "${cfg}" "${WORK}/configs/hostbot/instance-${n}/aura.cfg"
    done
fi
cp -a "${REPO_DIR}/maps/registry.yaml" "${WORK}/configs/registry.yaml"

install -d "${BACKUP_ROOT}"
TARBALL="${BACKUP_ROOT}/wc3-backup-${STAMP}.tar.gz"
tar -czf "${TARBALL}" -C "${WORK}" dump configs
chmod 600 "${TARBALL}"
log "backup escrito: ${TARBALL} ($(du -h "${TARBALL}" | cut -f1))"

# --- Retencion: dejar los 14 mas nuevos --------------------------------------
mapfile -t old < <(find "${BACKUP_ROOT}" -maxdepth 1 -name 'wc3-backup-*.tar.gz' \
    -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2- | tail -n +15)
if [[ "${#old[@]}" -gt 0 ]]; then
    log "borrando ${#old[@]} backups viejos"
    rm -f "${old[@]}"
fi

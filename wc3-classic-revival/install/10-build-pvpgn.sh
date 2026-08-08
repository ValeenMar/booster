#!/usr/bin/env bash
# ============================================================================
# 10-build-pvpgn.sh — clona, parchea, compila e instala PvPGN en /opt/wc3/pvpgn
# Correr con sudo. Idempotente: re-correrlo recompila e instala de nuevo.
#
# Validado en sandbox Ubuntu 24.04 + GCC 13.3 el 2026-08-08 (ver DECISIONES.md):
# compila OK con un solo parche (my_bool, removido en libmysqlclient 8.0).
# ============================================================================
set -euo pipefail

PVPGN_REPO="${WC3_PVPGN_REPO:-https://github.com/pvpgn/pvpgn-server.git}"
# Commit validado en sandbox; actualizar a conciencia, no a ciegas.
PVPGN_REF="${WC3_PVPGN_REF:-9cd173f4e02ba3d9f8f15a67ca308b5eb78723e4}"
PREFIX=/opt/wc3/pvpgn
SRC_DIR=/opt/wc3/src/pvpgn-server

log() { printf '[build-pvpgn] %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Correr con sudo (instala en ${PREFIX})." >&2
    exit 1
fi

# --- Fuente ------------------------------------------------------------------
install -d /opt/wc3/src
if [[ -d "${SRC_DIR}/.git" ]]; then
    log "repo ya clonado, actualizando"
    git -C "${SRC_DIR}" fetch --all --tags
else
    log "clonando ${PVPGN_REPO}"
    git clone "${PVPGN_REPO}" "${SRC_DIR}"
fi
git -C "${SRC_DIR}" checkout --force "${PVPGN_REF}"

# --- Parche my_bool (MySQL >= 8.0.1 elimino el typedef) ----------------------
# Upstream sigue usando my_bool en sql_mysql.cpp; con libmysqlclient 8.x de
# Ubuntu 24.04 el build corta. bool es un reemplazo directo.
if grep -q '\bmy_bool\b' "${SRC_DIR}/src/bnetd/sql_mysql.cpp"; then
    log "aplicando parche my_bool -> bool en sql_mysql.cpp"
    sed -i 's/\bmy_bool\b/bool/g' "${SRC_DIR}/src/bnetd/sql_mysql.cpp"
fi

# --- Compilar ----------------------------------------------------------------
log "configurando cmake (MySQL ON, Diablo2 OFF)"
cmake -S "${SRC_DIR}" -B "${SRC_DIR}/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_MYSQL=ON \
    -DWITH_D2CS=OFF \
    -DWITH_D2DBS=OFF \
    -DWITH_LUA=OFF \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}"
log "compilando (esto tarda unos minutos)"
cmake --build "${SRC_DIR}/build" -j "$(nproc)"

# --- Instalar ----------------------------------------------------------------
# make install NO pisa los .conf existentes si ya fueron editados? Si los pisa:
# por eso las configs reales se generan con 40-render-configs.sh que hace
# backup fechado antes de escribir. Aca instalamos binarios + samples.
log "instalando en ${PREFIX}"
cmake --install "${SRC_DIR}/build"
chown -R wc3:wc3 "${PREFIX}/var"

# --- Unidad systemd ----------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log "instalando unidad systemd pvpgn.service"
install -m 644 "${REPO_DIR}/systemd/pvpgn.service" /etc/systemd/system/pvpgn.service
systemctl daemon-reload

log "OK. Binario: ${PREFIX}/sbin/bnetd ($("${PREFIX}/sbin/bnetd" -v | head -1))"
log "Proximo paso: install/20-build-hostbot.sh"

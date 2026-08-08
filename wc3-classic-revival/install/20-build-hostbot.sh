#!/usr/bin/env bash
# ============================================================================
# 20-build-hostbot.sh — clona, parchea, compila e instala Aura en /opt/wc3/hostbot
# Correr con sudo. Idempotente.
#
# Validado en sandbox Ubuntu 24.04 + GCC 13.3 el 2026-08-08 (ver DECISIONES.md):
# compila OK agregando #include <cstdint> a los headers que usan uint*_t
# (libstdc++ 13 dejo de incluirlo transitivamente). StormLib y bncsutil vienen
# vendored en el mismo repo y se compilan primero.
# ============================================================================
set -euo pipefail

AURA_REPO="${WC3_AURA_REPO:-https://github.com/Josko/aura-bot.git}"
# Commit validado en sandbox (ultimo del upstream, 2018-09-09).
AURA_REF="${WC3_AURA_REF:-1e5df425fd325e9b0e6aa8fa5eed35f0c61f3114}"
DEST=/opt/wc3/hostbot
SRC_DIR=/opt/wc3/src/aura-bot

log() { printf '[build-hostbot] %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Correr con sudo (instala en ${DEST})." >&2
    exit 1
fi

# --- Fuente ------------------------------------------------------------------
install -d /opt/wc3/src
if [[ -d "${SRC_DIR}/.git" ]]; then
    log "repo ya clonado, actualizando"
    git -C "${SRC_DIR}" fetch --all --tags
else
    log "clonando ${AURA_REPO}"
    git clone "${AURA_REPO}" "${SRC_DIR}"
fi
git -C "${SRC_DIR}" checkout --force "${AURA_REF}"

# --- Parche cstdint (GCC/libstdc++ >= 13) ------------------------------------
# Varios headers usan uint8_t/uint32_t sin incluir <cstdint>; con toolchains
# viejos entraba transitivamente, con GCC 13 el build corta. Insertamos el
# include al principio de cada header afectado (idempotente por el grep -L).
log "aplicando parche cstdint a headers que lo necesiten"
for h in "${SRC_DIR}"/src/*.h; do
    if grep -qE 'u?int(8|16|32|64)_t' "$h" && ! grep -q '<cstdint>' "$h"; then
        sed -i '0,/^#include/s//#include <cstdint>\n#include/' "$h"
        log "  parcheado: $(basename "$h")"
    fi
done

# --- StormLib (vendored) -----------------------------------------------------
log "compilando StormLib"
cmake -S "${SRC_DIR}/StormLib" -B "${SRC_DIR}/StormLib/build" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_DYNAMIC_MODULE=1
cmake --build "${SRC_DIR}/StormLib/build" -j "$(nproc)"
cmake --install "${SRC_DIR}/StormLib/build"

# --- bncsutil (vendored) -----------------------------------------------------
log "compilando bncsutil"
make -C "${SRC_DIR}/bncsutil/src/bncsutil"
make -C "${SRC_DIR}/bncsutil/src/bncsutil" install
ldconfig

# --- Aura --------------------------------------------------------------------
log "compilando aura++ (el link con LTO tarda)"
make -C "${SRC_DIR}"

# --- Instalar ----------------------------------------------------------------
log "instalando en ${DEST}"
install -d -o wc3 -g wc3 "${DEST}" "${DEST}/mapcfgs" "${DEST}/instances"
install -m 755 "${SRC_DIR}/aura++" "${DEST}/aura++"
# ip-to-country: Aura lo busca en su directorio de trabajo; lo copiamos a cada
# instancia en 40-render-configs.sh. Guardamos el original aca.
install -m 644 "${SRC_DIR}/ip-to-country.csv" "${DEST}/ip-to-country.csv"
chown -R wc3:wc3 "${DEST}"

# --- Unidad systemd ----------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log "instalando unidad systemd wc3-hostbot@.service"
install -m 644 "${REPO_DIR}/systemd/wc3-hostbot@.service" /etc/systemd/system/wc3-hostbot@.service
systemctl daemon-reload

log "OK. Binario: ${DEST}/aura++"
log "Proximo paso: install/30-setup-mysql.sh"

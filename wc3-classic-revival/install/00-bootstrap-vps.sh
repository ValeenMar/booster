#!/usr/bin/env bash
# ============================================================================
# 00-bootstrap-vps.sh — deja un Ubuntu 24.04 recien creado listo para el stack
# Correr como root (o con sudo) UNA vez; es idempotente, se puede re-correr.
#
#   sudo ./install/00-bootstrap-vps.sh [usuario_admin]
#
# Hace: usuario admin con sudo, hardening de SSH, ufw, fail2ban, timezone,
# swap si hay poca RAM, usuario de sistema wc3, arbol /opt/wc3 y dependencias
# de compilacion de PvPGN y Aura.
# ============================================================================
set -euo pipefail

ADMIN_USER="${1:-wc3admin}"
TIMEZONE="${WC3_TIMEZONE:-America/Argentina/Buenos_Aires}"
# Rango de puertos de los hostbots; mantener en sintonia con WC3_BOT_PORT_RANGE
BOT_PORT_RANGE="${WC3_BOT_PORT_RANGE:-6113:6140}"

log() { printf '[bootstrap] %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Este script tiene que correr como root (sudo)." >&2
    exit 1
fi

# --- Paquetes ----------------------------------------------------------------
log "instalando paquetes base y dependencias de compilacion"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# build-essential/cmake/git: PvPGN y Aura
# default-libmysqlclient-dev: backend MySQL de PvPGN
# libgmp-dev/libbz2-dev/zlib1g-dev/m4: bncsutil y StormLib (Aura)
# gettext-base: envsubst para render de configs
apt-get install -y -q \
    build-essential cmake git m4 \
    default-libmysqlclient-dev \
    libgmp-dev libbz2-dev zlib1g-dev \
    mysql-server \
    ufw fail2ban \
    gettext-base python3 python3-pip python3-venv \
    python3-yaml python3-jsonschema \
    curl unzip

# venv para las dependencias de inspect-map.py que no estan empaquetadas en
# Ubuntu (mpyq no instala contra el setuptools parcheado de Debian fuera de
# un venv; verificado en sandbox 2026-08-08)
if [[ ! -x /opt/wc3/venv/bin/python ]]; then
    log "creando venv /opt/wc3/venv (mpyq + pyyaml)"
    install -d /opt/wc3
    python3 -m venv /opt/wc3/venv
    /opt/wc3/venv/bin/pip install --quiet mpyq pyyaml
fi

# --- Timezone ----------------------------------------------------------------
log "timezone -> ${TIMEZONE}"
timedatectl set-timezone "${TIMEZONE}"

# --- Usuario admin con sudo --------------------------------------------------
if ! id "${ADMIN_USER}" &>/dev/null; then
    log "creando usuario admin ${ADMIN_USER}"
    adduser --disabled-password --gecos '' "${ADMIN_USER}"
    usermod -aG sudo "${ADMIN_USER}"
    # Copiar las authorized_keys de root si existen, para no quedar afuera
    if [[ -f /root/.ssh/authorized_keys ]]; then
        install -d -m 700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
        install -m 600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" \
            /root/.ssh/authorized_keys "/home/${ADMIN_USER}/.ssh/authorized_keys"
    fi
else
    log "usuario ${ADMIN_USER} ya existe, sigo"
fi

# --- Hardening de SSH --------------------------------------------------------
# Antes de deshabilitar password/root, verificar que el admin tenga una key,
# si no te quedas afuera del VPS.
if [[ ! -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]]; then
    log "ATENCION: /home/${ADMIN_USER}/.ssh/authorized_keys esta vacio."
    log "Cargá tu clave publica ahi y re-corré este script para endurecer SSH."
else
    log "endureciendo sshd (sin password, sin root login)"
    install -d /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/90-wc3-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
X11Forwarding no
EOF
    systemctl reload ssh
fi

# --- Firewall ----------------------------------------------------------------
log "configurando ufw (SSH, 6112/tcp, bots ${BOT_PORT_RANGE}/tcp)"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 6112/tcp comment 'PvPGN bnetd'
ufw allow "${BOT_PORT_RANGE}/tcp" comment 'hostbots Aura'
# 6112/udp: los clientes W3 hacen un test UDP contra el server; sin esto
# funciona igual pero con latencia de deteccion. Lo abrimos por las dudas.
ufw allow 6112/udp comment 'PvPGN udptest'
ufw --force enable

# --- fail2ban ----------------------------------------------------------------
log "activando fail2ban (jail sshd por defecto)"
systemctl enable --now fail2ban

# --- Swap si hay menos de 2 GB de RAM ---------------------------------------
mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
if [[ "${mem_kb}" -lt 2000000 && ! -f /swapfile ]]; then
    log "menos de 2 GB de RAM: creando swap de 2 GB"
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Usuario de sistema wc3 y arbol /opt/wc3 ---------------------------------
if ! id wc3 &>/dev/null; then
    log "creando usuario de sistema wc3 (sin shell de login)"
    useradd --system --home-dir /opt/wc3 --shell /usr/sbin/nologin wc3
fi
log "creando arbol /opt/wc3"
install -d -o wc3 -g wc3 /opt/wc3 /opt/wc3/maps /opt/wc3/logs /opt/wc3/backups
# mpq: los archivos del juego los aporta el operador; read-only para wc3
install -d -o root -g wc3 -m 750 /opt/wc3/mpq

log "bootstrap OK. Proximo paso: install/10-build-pvpgn.sh"

# ============================================================================
# Template de aura.cfg para wc3-classic-revival
# ----------------------------------------------------------------------------
# Derivado del aura.cfg de ejemplo del upstream (github.com/Josko/aura-bot,
# commit 1e5df42, 2018-09-09). TODAS las claves existen en ese sample; no hay
# claves inventadas. Los placeholders WC3_* se rellenan con install/40-render-configs.sh
# a partir de .env + config/hostbot/instance-N.env.
#
# Aura lee "aura.cfg" desde su directorio de trabajo (esta hardcodeado en
# src/aura.cpp, no acepta la ruta por argumento). Por eso cada instancia del
# bot vive en /opt/wc3/hostbot/instances/N/ con su propio aura.cfg y la unidad
# systemd usa WorkingDirectory=%i.
# ============================================================================

# ---------------------------------------------------------------------------
# BOT
# ---------------------------------------------------------------------------

# Directorio con war3.exe, storm.dll y game.dll (los aporta el operador, no
# estan en el repo). Si contiene War3Patch.mpq, Aura extrae common.j y
# blizzard.j para calcular map_crc automaticamente.
bot_war3path = ${WC3_MPQ_DIR}

# Vacio = bindea a todas las interfaces. En un VPS con IP publica directa
# (sin NAT) esto es lo correcto.
bot_bindaddress =

# Puerto en el que ESTA instancia hostea partidas. Tiene que ser unico por
# instancia y estar abierto en ufw (rango WC3_BOT_PORT_RANGE del .env).
bot_hostport = ${WC3_BOT_HOSTPORT}

# Puerto para reconexiones GProxy++ (unico por instancia tambien).
bot_reconnectport = ${WC3_BOT_RECONNECTPORT}
bot_reconnectwaittime = 3

# Partidas simultaneas por instancia. En un VPS de 2 GB, conservador.
bot_maxgames = ${WC3_BOT_MAXGAMES}

bot_commandtrigger = !

# Configs de mapa (.cfg generados por el bot) y mapas .w3x compartidos entre
# todas las instancias.
bot_mapcfgpath = ${WC3_HOSTBOT_DIR}/mapcfgs
bot_mappath = ${WC3_MAPS_DIR}/

# Nombre virtual del host en el lobby (max 15 caracteres incluyendo el codigo
# de color |cFFxxxxxx).
bot_virtualhostname = ${WC3_BOT_VIRTUALHOST}

bot_autolock = 0

# 1 = los jugadores pueden bajar el mapa desde el bot (clave para mapas
# custom; limite practico de ~4 MB en 1.26a, ver docs/version-1.26a.md).
bot_allowdownloads = 1
bot_maxdownloaders = 3

# KB/s combinados para descargas in-lobby. Subilo si el VPS tiene banda.
bot_maxdownloadspeed = ${WC3_BOT_MAXDLSPEED}

bot_lcpings = 1

# Kick automatico por ping. Para publico sudamericano con server en Sao Paulo
# o Buenos Aires, 300 ms es generoso sin dejar entrar jugadores injugables.
bot_autokickping = 300

bot_lobbytimelimit = 10
bot_latency = 100
bot_synclimit = 50
bot_votekickpercentage = 70

# Mapa por defecto que hostea esta instancia (nombre del .cfg en mapcfgs, la
# extension .cfg se agrega sola).
bot_defaultmap = ${WC3_BOT_DEFAULTMAP}

bot_gameoverplayernumber = 1

# ---------------------------------------------------------------------------
# LAN
# ---------------------------------------------------------------------------

# Version de W3 para el broadcast LAN. 26 = 1.26x.
# TODO(verificar): el sample del upstream trae 29 (1.29); confirmar con el
# juego real que este build de Aura acepta clientes 1.26a con este valor.
lan_war3version = ${WC3_WAR3_VERSION}

udp_broadcasttarget =
udp_dontroute = 0

# ---------------------------------------------------------------------------
# BASE DE DATOS (sqlite local por instancia: bans, stats de DotA, admins)
# ---------------------------------------------------------------------------

db_sqlite3_file = aura.dbs

# ---------------------------------------------------------------------------
# IRC (no se usa; queda vacio)
# ---------------------------------------------------------------------------

irc_server =
irc_port = 6667
irc_nickname =
irc_username =
irc_password =
irc_commandtrigger =
irc_channel =
irc_rootadmin =

# ---------------------------------------------------------------------------
# BATTLE.NET (nuestro PvPGN local)
# ---------------------------------------------------------------------------

# El bot se conecta al PvPGN del mismo VPS por loopback.
bnet_server = 127.0.0.1
bnet_serveralias = ${WC3_REALM_NAME}

# En PvPGN las CD keys no se validan: el sample upstream indica dejarlas asi.
bnet_cdkeyroc = FFFFFFFFFFFFFFFFFFFFFFFFFF
bnet_cdkeytft = FFFFFFFFFFFFFFFFFFFFFFFFFF

bnet_locale = system

# Cuenta del bot en el PvPGN. Crearla antes con el cliente o via bnetd
# (new_accounts = true) — ver RUNBOOK fase 1.
bnet_username = ${WC3_BOT_USERNAME}
bnet_password = ${WC3_BOT_PASSWORD}

bnet_firstchannel = ${WC3_BOT_CHANNEL}

# Admins raiz del bot (separados por espacio, cuentas del PvPGN).
bnet_rootadmins = ${WC3_BOT_ROOTADMINS}

bnet_commandtrigger = !

# --- Seccion PvPGN custom (obligatoria contra un PvPGN, no Blizzard) -------
# TODO(verificar): estos cuatro valores dependen del par cliente/servidor real
# y solo se pueden confirmar conectando el bot a un PvPGN con clientes 1.26a.
# war3version 26 = 1.26x. exeversion/exeversionhash: si se dejan vacios, Aura
# intenta calcularlos con bncsutil a partir de los archivos de bot_war3path
# (war3.exe/storm.dll/game.dll de 1.26a). passwordhashtype pvpgn es lo
# documentado para servidores PvPGN en el propio sample.
bnet_custom_war3version = ${WC3_WAR3_VERSION}
bnet_custom_exeversion =
bnet_custom_exeversionhash =
bnet_custom_passwordhashtype = pvpgn
bnet_custom_pvpgnrealmname = ${WC3_REALM_NAME}

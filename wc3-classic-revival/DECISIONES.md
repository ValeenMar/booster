# DECISIONES

Registro de decisiones tomadas sin consultar, con sus alternativas y los
resultados reales de compilación. Convención de estados de verificación:

- **validado en seco**: chequeado con linters/tests sin VPS ni juego
- **compilado y probado**: compilado de verdad y ejecutado en sandbox
- **requiere prueba con el juego real**: solo se confirma con clientes 1.26a

---

## 1. Resultados de compilación (sandbox Ubuntu 24.04.4, GCC 13.3, 2026-08-08)

El sandbox donde se desarrolló este repo es exactamente el toolchain destino
(Ubuntu 24.04 LTS, GCC 13.3.0, CMake 3.28.3), así que estos resultados son
representativos del VPS.

### PvPGN (github.com/pvpgn/pvpgn-server, commit `9cd173f`, HEAD 2026-08-08)

**Estado: compilado y probado.**

- Configuración: `cmake -DWITH_MYSQL=ON -DWITH_D2CS=OFF -DWITH_D2DBS=OFF -DWITH_LUA=OFF`.
- **Falló al primer intento**: `src/bnetd/sql_mysql.cpp` usa `my_bool`, un
  typedef que MySQL eliminó del cliente en 8.0.1. Ubuntu 24.04 trae
  libmysqlclient 8.0.46 → `error: 'my_bool' was not declared in this scope`.
- **Parche**: `sed -i 's/\bmy_bool\b/bool/g' src/bnetd/sql_mysql.cpp` (en
  MySQL >= 8.0 `my_bool` era exactamente `bool`; reemplazo directo, sin
  cambio semántico). Automatizado en `install/10-build-pvpgn.sh`.
- Con el parche compila limpio y linkea. `bnetd -v` → `PvPGN 1.99.7.2.1-PRO`.
- **Smoke test**: `bnetd -f` con la config default (storage file) arranca,
  suelta privilegios de root, y escucha en `0.0.0.0:6112` (bnet) y
  `0.0.0.0:6200` (w3route). No se probó el backend MySQL en runtime (no hay
  mysqld en el sandbox): **requiere prueba en el VPS**, aunque el driver
  compiló y PvPGN crea las tablas solo (ver decisión 6).
- Dependencias usadas: `default-libmysqlclient-dev` 1.1.0 (→ libmysqlclient
  8.0.46), zlib1g-dev.
- Dato útil: el `versioncheck.json` que instala upstream **ya trae la entrada
  de TFT 1.26a** (`"Warcraft III - TFT (Expansion) 1.26a"`, version
  `1.26.0.1`, hash `0xf2e7cec2`, tag `W3XP_126A`). No hay que fabricar
  entradas de versioncheck.

### Aura-bot (github.com/Josko/aura-bot, commit `1e5df42`, último del upstream, 2018-09-09)

**Estado: compilado y probado.**

- **Falló al primer intento**: ~8 headers (`bnetprotocol.h`, `gameslot.h`,
  `map.h`, `socket.h`, etc.) usan `uint8_t/uint32_t` sin incluir `<cstdint>`.
  Con libstdc++ de GCC <= 12 entraba transitivamente; GCC 13 lo dejó de
  arrastrar → cascada de `'uint8_t' was not declared in this scope`.
- **Parche**: insertar `#include <cstdint>` al inicio de cada header que usa
  `u?int(8|16|32|64)_t` y no lo incluye. Automatizado (e idempotente) en
  `install/20-build-hostbot.sh`.
- StormLib y bncsutil vienen *vendored* dentro del repo de Aura y compilaron
  sin tocar nada (StormLib vía CMake, bncsutil vía make; dependencias: libgmp,
  libbz2, zlib, m4). Se instalan en /usr/local + ldconfig, como documenta el
  README del upstream.
- El link final de `aura++` usa `-flto` y tarda varios minutos en 4 vCPU; es
  normal, no está colgado.
- **Smoke test**: `aura++` arranca, lee `aura.cfg`, abre su sqlite `aura.dbs`
  y queda corriendo. La conexión a un PvPGN con clientes 1.26a **requiere
  prueba con el juego real**.

---

## 2. Aura y no GHost++ como hostbot

**Decisión**: Aura-bot (fork moderno de GHost++, C++14, sqlite integrado).

- A favor: base de código mucho más chica y sana que GHost++, compila casi
  limpio en toolchains modernos (solo el parche cstdint), sin dependencias
  muertas (GHost++ clásico requiere Boost viejo y MySQL antiguos).
- En contra / riesgo: el upstream apunta a parches 1.28+ (su sample trae
  `war3version = 29`). Para 1.26a seteamos `WC3_WAR3_VERSION=26`.
  **TODO(verificar) crítico**: que este build acepte clientes 1.26a y calcule
  bien `exeversion/exeversionhash` contra los MPQ de 1.26a. Si no funciona,
  el plan B documentado es GHost++ clásico (ghostplusplus), que es de la era
  1.26 — a costa de pelearse con su build.
- Si me dijeran "compatibilidad con mapas/clientes viejos por encima de
  todo": arrancaría directamente por GHost++ 17.x o el fork ghost-one usado
  por comunidades 1.26 de la época, aceptando el dolor de build.

## 3. Instancias de Aura como directorios + unidad systemd instanciada

**Decisión**: cada bot vive en `/opt/wc3/hostbot/instances/N/` con su propio
`aura.cfg`, y `wc3-hostbot@.service` usa `WorkingDirectory=.../instances/%i`.

- Motivo (verificado en el código): `src/aura.cpp` hace `CFG.Read("aura.cfg")`
  — la ruta está **hardcodeada relativa al directorio de trabajo**, no acepta
  config por argumento. La unidad instanciada del enunciado
  (`instance-%i.cfg` plano) no es posible sin parchear Aura; el layout por
  directorios logra lo mismo (alta de bot = un `.env` nuevo + render +
  `systemctl enable --now wc3-hostbot@3`) sin tocar el código.
- Costo: cada instancia tiene su `aura.dbs` (bans/stats separados por bot).
  Para fase 1-2 es aceptable; unificar stats es parte de la fase 3.

## 4. Templates renderizados con envsubst con whitelist WC3_*

**Decisión**: los templates usan solo placeholders `${WC3_*}` y el render
pasa a `envsubst` la lista explícita de variables con ese prefijo.

- Motivo: los conf de PvPGN usan `${...}` con otro significado (p. ej.
  `${prefix}` en `sql_DB_layout.conf`); un envsubst sin whitelist los
  destrozaría en silencio.
- El render valida que no quede ningún `${WC3_` vivo y aborta si falta una
  variable. Validado en seco (validate.sh renderiza con `.env.example`).

## 5. bnetd.conf.tpl derivado del sample real, no escrito a mano

**Decisión**: `config/pvpgn/bnetd.conf.tpl` es el `bnetd.conf` que instala el
propio build de PvPGN (con las rutas /opt/wc3/pvpgn ya renderizadas por su
CMake), con exactamente 7 valores parametrizados (storage_path, servaddrs,
location, description, url, contact_name, contact_email) y `track = 0`
(server privado: no anunciarse a trackers públicos).

- Garantía: cero claves inventadas; todo lo demás queda en los defaults del
  upstream, que el smoke test cargó sin errores.
- Lo mismo para `address_translation.conf.tpl`: es el sample upstream más una
  única regla para el w3route (`0.0.0.0:6200 -> ${WC3_PUBLIC_IP}:6200`),
  siguiendo el ejemplo comentado del propio archivo.

## 6. MySQL: el script solo crea base y usuario; las tablas las crea PvPGN

**Decisión**: `30-setup-mysql.sh` crea `pvpgn`@localhost y la base, nada más.

- Motivo (verificado en fuente y en el conf): PvPGN crea las tablas en el
  primer arranque desde `etc/pvpgn/sql_DB_layout.conf` (el archivo lo dice
  textualmente: "the server will create the tables ... don't forget to create
  the DB yourself"; el código está en `src/bnetd/sql_dbcreator.cpp`).
  Duplicar el schema a mano en el repo sería inventarlo y desincronizarse.
- **Requiere prueba en el VPS**: primer arranque de bnetd contra MySQL real.

## 7. Pins de commit en los scripts de build

**Decisión**: `10-build-pvpgn.sh` y `20-build-hostbot.sh` clonan y hacen
checkout de los commits exactos validados en sandbox (`9cd173f` y `1e5df42`),
sobreescribibles por variables `WC3_PVPGN_REF` / `WC3_AURA_REF`.

- Motivo: lo único que sé con certeza es que ESTOS commits compilan con ESTOS
  parches en ESTE toolchain. Un HEAD futuro puede romper el parche o
  arreglarlo; en ambos casos quiero que sea una decisión consciente.

## 8. Sin Docker, sin CI, sin monitoreo

Pedido explícito del enunciado; la ruta de migración a contenedores y sus
trampas (NAT/bridge vs anuncio de IP en protocolo) quedan en
`docs/docker-futuro.md`.

## 9. mpyq en venv, no en el sistema

**Decisión**: `inspect-map.py` usa stdlib para el header HM3W y `mpyq` solo
si está disponible; el bootstrap crea `/opt/wc3/venv` con mpyq+pyyaml.

- Motivo (verificado en sandbox): `pip install mpyq` contra el Python del
  sistema en Ubuntu 24.04 **falla** (`AttributeError: install_layout`, el
  setup.py de 2015 de mpyq choca con el setuptools parcheado de Debian).
  Dentro de un venv limpio instala perfecto.
- Bonus del diseño: el header HM3W (nombre y max jugadores) vive FUERA del
  MPQ, así que se lee incluso en mapas protegidos y sin mpyq.
- Limitación honesta: mpyq exige el magic MPQ al inicio del archivo; los
  .w3x lo tienen en offset 512, así que el script recorta el prefijo antes de
  abrirlo. El parser de `war3map.w3i` está validado contra .w3i sintéticos
  (tests) — **la validación con mapas reales es parte de la fase 1**.

## 10. Las 3 decisiones más discutibles (resumen ejecutivo)

1. **Aura (2018) para un servidor 1.26a** — ver decisión 2. Es el riesgo
   funcional más grande después de los ya resueltos de compilación.
2. **Instancias por directorio en vez de `instance-%i.cfg` plano** — impuesto
   por el hardcode de Aura; cambia la forma del enunciado pero no el fondo.
3. **`track = 0` y server "privado por oscuridad"** (cuentas abiertas,
   `new_accounts = true` del default upstream) — cómodo para amigos, pero
   cualquiera que encuentre la IP puede crearse cuenta. Alternativa anotada
   en docs/operacion.md: cerrar `new_accounts` después de la fase 1.

---

## TODO(verificar) — lista completa, ordenada por qué bloquea primero

1. **Aura + clientes 1.26a contra PvPGN** (bloquea fase 1): con
   `war3version=26` y `exeversion/exeversionhash` vacíos (autocálculo desde
   los MPQ), el bot tiene que loguearse al PvPGN y los clientes tienen que
   poder entrar a sus lobbies. Plan B: GHost++ clásico.
2. **PvPGN + MySQL en runtime** (bloquea fase 1): primer arranque crea las
   tablas desde `sql_DB_layout.conf`. Compiló, pero no se ejecutó contra un
   mysqld real.
3. **Autenticación de clientes 1.26a reales** (bloquea fase 1): el
   versioncheck de fábrica trae W3XP_126A; con `allow_bad_version=true` y
   `allow_unknown_version=true` (defaults) debería entrar cualquier 1.26a,
   pero solo un cliente real lo confirma.
4. **`bot_maxdownloadspeed`/descarga in-lobby de mapas <4 MB** (fase 1-2):
   el límite de 4 MB es del cliente 1.26a, no del bot; confirmar con un mapa
   grande que la descarga se rechaza y el map pack es necesario.
5. **Parser de war3map.w3i contra mapas reales** (fase 2): validado solo
   contra .w3i sintéticos; probar con 2-3 mapas reales (uno RoC fmt 18, uno
   TFT fmt 25, uno protegido).
6. **Hardening de systemd vs StormLib** (fase 1): `ProtectSystem=strict` con
   `ReadWritePaths` puede pisar algún acceso inesperado de Aura (p. ej.
   escribir logs junto al binario). Si una instancia muere al arrancar,
   relajar primero `ProtectSystem` y reportar.
7. **`MemoryMax=384M` por instancia de bot** (fase 2): estimación
   conservadora; medir con `systemctl status` bajo carga real de 2 partidas.

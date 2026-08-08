# wc3-classic-revival

Infraestructura completa para un **servidor privado de Warcraft III: The
Frozen Throne 1.26a** orientado a mapas custom clásicos (2004-2010):
[PvPGN](https://github.com/pvpgn/pvpgn-server) como emulador de Battle.net +
[Aura](https://github.com/Josko/aura-bot) como hostbot de partidas.
**Instalación nativa sobre Ubuntu 24.04 con systemd, sin Docker** (el porqué:
`docs/docker-futuro.md`).

Ambos componentes **compilan verificadamente** en Ubuntu 24.04 / GCC 13 con
dos parches de una línea que los scripts aplican solos (detalle completo y
honesto en `DECISIONES.md`). Este repo no contiene ni descarga ningún archivo
del juego ni mapas: eso lo aporta el operador (`.gitignore` lo bloquea).

## Quickstart

```bash
# En tu maquina: validar el repo en seco (sin VPS, sin juego)
./scripts/validate.sh

# En el VPS (Ubuntu 24.04 limpio):
sudo ./install/00-bootstrap-vps.sh tuusuario   # sistema, firewall, deps
cp .env.example .env && nano .env              # IP publica, passwords
make build                                     # compila PvPGN + Aura
sudo ./install/30-setup-mysql.sh               # base de datos
make render-config                             # templates + .env -> configs
# copiar war3.exe/storm.dll/game.dll/War3Patch.mpq (1.26a) a /opt/wc3/mpq/
sudo systemctl enable --now pvpgn wc3-hostbot@1
```

El paso a paso real, con criterios de "listo" por fase, está en
**`RUNBOOK.md`**. La conexión del lado del jugador, en `docs/clientes.md`.

## Mapa del repo

| Ruta | Qué es |
|------|--------|
| `RUNBOOK.md` | las 4 fases del proyecto, con checklist |
| `DECISIONES.md` | decisiones, resultados de compilación, TODOs de verificación |
| `install/*.sh` | bootstrap del VPS, builds, MySQL, render de configs |
| `systemd/` | `pvpgn.service` y `wc3-hostbot@.service` (instanciada) |
| `config/` | templates de configuración (placeholders `${WC3_*}` + `.env`) |
| `maps/registry.yaml` | **el catálogo**: 21 mapas con estado y riesgo 1.24+ |
| `scripts/inspect-map.py` | lee un `.w3x` y alimenta el registry |
| `scripts/validate.sh` | valida TODO en seco; tiene que estar en verde |
| `docs/` | versión 1.26a y return bug, mapas, clientes, operación, Docker futuro |

## Layout en el servidor

Todo bajo `/opt/wc3/`, dueño el usuario de sistema `wc3` (sin shell):
`pvpgn/` (binarios+configs+datos), `hostbot/` (aura++ e `instances/N/`),
`maps/` (los .w3x), `mpq/` (archivos del juego, read-only), `backups/`,
`venv/` (mpyq para inspección de mapas).

## Estado de verificación

- **Compilado y probado en sandbox**: PvPGN (bnetd arranca y escucha) y Aura
  (arranca y lee config). 
- **Validado en seco**: scripts (shellcheck), unidades (systemd-analyze),
  registry (schema), templates (render completo), inspect-map (6 tests).
- **Pendiente de juego real**: login del bot 1.26a, MySQL en runtime,
  validación de mapas — lista priorizada al final de `DECISIONES.md`.

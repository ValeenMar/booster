# RUNBOOK — de cero a servidor con web, en cuatro fases

Cada fase tiene un criterio de "listo" verificable. No arrancar una fase sin
cerrar la anterior. Antes de todo: `./scripts/validate.sh` en verde en tu
máquina.

---

## Fase 0 (previa): lo que hay que conseguir

- [ ] VPS Ubuntu 24.04 LTS, 2 vCPU / 2-4 GB, en São Paulo o Buenos Aires,
      con IP pública propia (no CGNAT) y acceso SSH por clave.
- [ ] Instalación de W3 TFT **1.26a**: de ella salen `war3.exe`, `storm.dll`,
      `game.dll` y `War3Patch.mpq` para `/opt/wc3/mpq/`.
- [ ] Los primeros 3 mapas (sugeridos: DotA 6.83d, Footmen Frenzy, Sheep Tag
      — los tres `verde` en el registry).
- [ ] Dos personas con el juego instalado para la prueba de sincronía.

---

## Fase 1: PvPGN + 1 bot + 3 mapas, probado con dos clientes reales

### Instalación

```bash
# en el VPS, como root:
git clone <este-repo> && cd wc3-classic-revival
./install/00-bootstrap-vps.sh tuusuario      # prepara el sistema
# reconectarse como tuusuario si entraste como root
cp .env.example .env && nano .env            # IP publica, passwords, realm
make build                                   # compila PvPGN y Aura (~10 min)
sudo ./install/30-setup-mysql.sh             # base + usuario
make render-config                           # configs finales
```

### Archivos del juego

```bash
# desde tu maquina (sacados de una instalacion 1.26a):
scp war3.exe storm.dll game.dll War3Patch.mpq vps:/tmp/
# en el VPS:
sudo mv /tmp/{war3.exe,storm.dll,game.dll,War3Patch.mpq} /opt/wc3/mpq/
sudo chown root:wc3 /opt/wc3/mpq/* && sudo chmod 640 /opt/wc3/mpq/*
```

### Arranque y cuenta del bot

```bash
sudo systemctl enable --now pvpgn
tail -f /opt/wc3/pvpgn/var/pvpgn/bnetd.log   # ver: "listening ... 6112"
#   y que el primer arranque haya creado las tablas MySQL sin errores
#   (TODO(verificar) #2 de DECISIONES.md)

# crear la cuenta del bot: conectarse con el cliente W3 al server
# (docs/clientes.md) y loguearse una vez con WC3_BOT_USERNAME/PASSWORD
# (new_accounts=true crea la cuenta al primer login)

sudo systemctl enable --now wc3-hostbot@1
journalctl -u wc3-hostbot@1 -f               # ver: login al PvPGN OK
#   (TODO(verificar) #1: si el login falla por version, ver DECISIONES.md
#    decision 2 — plan B GHost++)
```

### Validación de los 3 mapas

Para cada mapa, el protocolo completo de docs/mapas.md:

1. Cargar en Custom Game **single player en 1.26a**; anotar que carga.
2. `inspect-map.py --update-registry`: tamaño y slots al registry.
3. Copiar a `/opt/wc3/maps/`, `!map ElMapa` en el canal del bot: el bot
   calcula el hash sin quejarse.
4. `!pub prueba` y entrar con **dos clientes reales desde redes distintas**:
   ambos entran al lobby, la partida arranca, 10 minutos sin desync ni drops.
5. Registry: `status: validado`, versión probada en `versions_known`.

### Criterio de listo

- [ ] `systemctl status pvpgn wc3-hostbot@1` ambos `active (running)` y
      sobreviven un `sudo reboot`.
- [ ] Dos clientes reales desde afuera crearon cuenta, chatearon en un canal,
      y jugaron una partida completa hosteada por el bot en cada uno de los
      3 mapas, sin desync.
- [ ] Los 3 mapas en `status: validado` en el registry.
- [ ] `make backup` corre y el tar contiene el dump.

---

## Fase 2: biblioteca de mapas + map pack distribuible

- Conseguir y validar el resto del catálogo (los 21 del registry), en orden:
  primero los `verde`, después `amarillo`, y los `rojo` al final (con plan B
  de remakes — ver notas del registry).
- Cada mapa pasa por el protocolo de docs/mapas.md; los >4 MB quedan
  marcados "solo map pack".
- Armar `wc3revival-maps-v01.zip` con todos los `validado` (docs/mapas.md,
  sección map pack) y publicarlo donde el grupo lo baje.
- Segunda instancia de bot arriba (`wc3-hostbot@2`, arena) con su canal.

### Criterio de listo

- [ ] Todo el catálogo en `validado` o `descartado` con nota (cero
      `pendiente`).
- [ ] Map pack v01 publicado; un jugador nuevo con el pack entra a cualquier
      partida sin descargar nada in-lobby.
- [ ] Dos bots corriendo con catálogos distintos.

---

## Fase 3: stats en MySQL + bot de Discord que anuncia lobbies

- Volcar stats de partidas a MySQL: Aura guarda stats (DotA incluida) en el
  sqlite `aura.dbs` de cada instancia; escribir un job (cron + python) que
  los consolide a la base MySQL junto a las cuentas PvPGN.
- Bot de Discord (discord.py o similar) que:
  - anuncia lobbies abiertos (leyendo el estado de los bots) con mapa y
    cantidad de slots libres,
  - publica resultados/stats básicos por jugador.
- Nada de esto toca la ruta de juego: si el bot de Discord muere, el server
  sigue.

### Criterio de listo

- [ ] Tabla(s) de stats en MySQL alimentadas automáticamente.
- [ ] Canal de Discord recibe "se abrió lobby de X" en <30 segundos.
- [ ] Consulta de stats de un jugador funcionando (aunque sea por comando).

---

## Fase 4: sitio web con registro de cuentas

- Web mínima (estática + un backend chico) con:
  - registro de cuenta PvPGN (escribiendo el hash a la base con el mismo
    formato que usa bnetd — verificar formato de `acct_passhash1` antes),
  - instrucciones de conexión (docs/clientes.md destilado + descarga del
    `.reg` de gateway),
  - link al map pack vigente y al Discord.
- HTTPS con caddy o nginx + certbot; abrir 80/443 en ufw recién acá.

### Criterio de listo

- [ ] Un amigo sin ayuda: entra a la web, se registra, configura el gateway,
      baja el pack y juega. Cero intervención manual del admin.

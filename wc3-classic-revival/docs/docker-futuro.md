# Migración futura a Docker (y por qué no hoy)

## Por qué la ruta principal es nativa

PvPGN y el hostbot **anuncian IP y puerto dentro del propio protocolo**:

- Cuando un jugador entra a una partida del bot, el bot le manda "conectate a
  IP:PUERTO" y el cliente abre un TCP directo ahí.
- El w3route de PvPGN hace lo mismo para partidas PG/AT (por eso existe
  `address_translation.conf`).

Con bridge networking de Docker aparece una capa de NAT: el proceso adentro
ve su IP de contenedor (172.17.x.x) y, si no se lo configura con cuidado,
**eso es lo que anuncia**. El cliente intenta conectarse a una IP privada
ajena y no entra a la partida. Es el mismo problema clásico de FTP activo o
SIP detrás de NAT: protocolos que meten direcciones en el payload no
atraviesan NAT sin ayuda.

Además, en fase de ajuste fino queremos `systemctl restart` + `journalctl`
por servicio y edición directa de configs, no rebuild/redeploy de imágenes.

## Cuándo tiene sentido migrar

- Cuando las configs estén congeladas (fase 3+).
- Si aparece un segundo servidor / entorno de prueba y queremos
  reproducibilidad exacta.
- Si el VPS se reinstala seguido y el bootstrap manual cansa.

## Cómo migrar sin romper el anuncio de IP/puerto

Regla de oro: **el puerto interno TIENE que ser igual al externo, y la IP
anunciada tiene que ser la pública del host.**

1. **Usar `network_mode: host`** para PvPGN y los bots. Elimina el NAT de
   Docker por completo: el contenedor escucha directo en las interfaces del
   host, exactamente como la instalación nativa. Es la opción recomendada y
   la única que no requiere tocar configs.
2. Si por algún motivo se insiste con bridge:
   - publicar cada puerto con mapeo idéntico (`-p 6112:6112`, `-p 6113:6113`,
     ...); jamás remapear (6113 externo → 6112 interno rompe el anuncio);
   - PvPGN: mantener la regla de `address_translation.conf` apuntando a la
     IP pública (ya lo hace este repo);
   - Aura: `bot_bindaddress` vacío pero verificar qué IP anuncia; el binario
     de 2018 no tiene una opción "IP externa" separada del bind —
     TODO(verificar) si el kernel de Docker le hace ver la IP del bridge,
     en cuyo caso bridge queda directamente descartado para el bot;
   - abrir los mismos puertos en ufw hacia el rango de contenedores.
3. **UDP 6112** (test de red y broadcast LAN) también va con puerto idéntico.

## Esbozo de layout cuando llegue el momento

- Imagen `pvpgn`: build multi-stage (compila con los mismos parches de
  `install/10-build-pvpgn.sh`, corre sobre ubuntu:24.04 pelado), volúmenes
  para `etc/pvpgn` y `var/pvpgn`.
- Imagen `hostbot`: idem con `install/20-build-hostbot.sh`; un contenedor por
  instancia montando `instances/N/` y `maps/` (ro) + `mpq/` (ro).
- MySQL: contenedor oficial `mysql:8` con volumen propio, o quedarse con el
  mysqld del host (menos piezas que migrar).
- systemd sigue siendo el supervisor (unidades que hacen `docker run`), así
  la operación (`systemctl restart`, `journalctl`) no cambia.

Los scripts de `install/` ya dejan los parches y versiones pinneadas
documentados, así que escribir los Dockerfiles va a ser transcribir, no
investigar de nuevo.

# Cómo se conecta un jugador

## Qué necesita el jugador

1. **Warcraft III: The Frozen Throne 1.26a** instalado (RoC + TFT). La
   instalación la consigue cada uno por su lado; este proyecto no distribuye
   archivos del juego.
2. La **IP (o dominio) del servidor**: la `WC3_PUBLIC_IP` del `.env`.
3. Para mapas grandes: el **map pack** descomprimido en
   `Warcraft III/Maps/Download/` (ver docs/mapas.md).

## Redirección de gateway (apuntar el cliente a nuestro PvPGN)

El cliente de W3 trae hardcodeadas las direcciones de Battle.net oficiales
("gateways"). Para entrar a un server PvPGN hay que agregar/redirigir un
gateway. Opciones, de la más simple a la más manual:

### Opción A: editor de gateways (recomendada)

Herramientas clásicas de la escena PvPGN ("BNGatewayEditor", "W3 Gateway
Editor" y equivalentes) agregan una entrada nueva sin tocar nada más. Datos a
cargar:

- **Nombre**: WC3 Revival (o el `WC3_REALM_NAME` que quede en el .env)
- **Dirección**: la IP pública del VPS
- **Puerto**: 6112
- **Timezone**: -3 (Argentina) — solo afecta cómo se muestra la hora

### Opción B: registro de Windows a mano

Los gateways viven en
`HKEY_CURRENT_USER\Software\Blizzard Entertainment\Warcraft III\Gateways`
(valor multi-string). Se puede exportar un `.reg` de ejemplo y pasárselo a
los amigos — queda para la fase 4 armar ese `.reg` con la IP definitiva.

### Opción C: DNS local / hosts

Redirigir un gateway oficial (ej. `useast.battle.net`) a nuestra IP vía
`C:\Windows\System32\drivers\etc\hosts`:

```
203.0.113.10 useast.battle.net
```

Funciona pero es invasivo (rompe el acceso al gateway real, irrelevante hoy)
y requiere admin. Preferir la opción A.

## Flujo del jugador

1. Abrir W3 → Battle.net → elegir el gateway nuevo.
2. **Crear cuenta**: con `new_accounts = true` (default actual), alcanza con
   poner usuario/contraseña nuevos en la pantalla de login la primera vez.
3. Entrar al canal (ej. `AoS`) donde está el bot, y usar sus comandos:
   `!games` (qué hay hosteado), o pedir una partida.
4. Entrar a la partida desde Custom Games; si el mapa pesa <4 MB lo baja del
   bot ahí mismo; si no, tiene que tener el map pack.

## Qué viaja por qué puerto (para diagnóstico)

| Puerto | Quién | Qué |
|--------|-------|-----|
| 6112/tcp | PvPGN | chat, login, lista de partidas |
| 6112/udp | PvPGN | test de red del cliente |
| 6200/tcp | PvPGN (w3route) | solo partidas PG/AT de ladder (no las custom del bot) |
| 6113+/tcp | cada bot | el juego en sí: el cliente se conecta AL PUERTO DEL BOT |

El dato crítico: cuando un jugador entra a una partida del bot, el bot le
anuncia **su IP:puerto dentro del protocolo** y el cliente abre una conexión
TCP directa a ese puerto. Por eso los puertos de los bots tienen que estar
abiertos en ufw y por eso NAT/bridge rompe todo (ver docs/docker-futuro.md).

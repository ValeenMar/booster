# Por qué 1.26a

## La versión objetivo

**Warcraft III: The Frozen Throne 1.26a** (marzo 2011) es la última versión
"clásica larga": fue el parche estable durante ~5 años (hasta 1.27a en 2016)
y es la versión canónica de las comunidades de mapas custom de la era
2004-2012. Prácticamente todo mapa mantenido después de 2009 declara soporte
para 1.24+ y fue jugado masivamente en 1.26a.

Puntos técnicos que importan para este proyecto:

- El `versioncheck.json` de PvPGN trae de fábrica la entrada
  `W3XP_126A` (version `1.26.0.1`, hash `0xf2e7cec2`), o sea que el server
  reconoce a los clientes 1.26a sin tocar nada.
- Los hostbots de la época (GHost++ y derivados como Aura) hablan el
  protocolo `war3version = 26`.
- Corre perfecto con Wine para quien juegue desde Linux.

## El return bug de JASS (por qué algunos mapas viejos NO cargan)

Hasta el parche 1.23, JASS permitía un exploit conocido como **return bug**:
una función que hacía `return` de un tipo reinterpretado como otro (típico
`return H2I(handle)`) permitía convertir handles en enteros y viceversa. Era
técnicamente un bug de type-checking, pero se volvió LA base de los sistemas
avanzados de la época (vJASS handle vars, sistemas de attachment, memoria
"extendida", etc.).

**El parche 1.24 (agosto 2009) lo eliminó** e introdujo los hashtables
nativos como reemplazo. Consecuencia:

- Mapa que usa return bug + nunca se actualizó → **no carga o crashea en
  1.24+**, incluida 1.26a. Es el caso de muchos mods chicos de 2005-2008
  (en nuestro catálogo: la familia de spinoffs de Pudge Wars, marcados
  `return_bug_risk: rojo`).
- Mapa mantenido → sacó versión "1.24 compatible" y funciona. Ejemplo
  canónico: **DotA 6.61b** fue la primera versión compatible con 1.24;
  cualquier DotA anterior no carga en 1.24+.

El campo `return_bug_risk` del registry clasifica exactamente este riesgo.
Para los rojos, el plan es: probar la última versión conocida del mapa, y si
no carga, buscar remakes post-2009 o descartarlo (documentándolo en el
registry con `status: descartado`).

## Límites de tamaño de mapa

- **4 MB**: techo de transferencia in-lobby en 1.26a y anteriores. Un mapa
  más grande no se puede descargar del bot al entrar al lobby: el jugador
  tiene que tenerlo de antemano. De ahí el **map pack versionado** de la
  fase 2 (los AoS de anime del catálogo casi todos superan los 4 MB).
- **8 MB**: techo absoluto de mapa que el cliente 1.26a carga (límite del
  formato/motor de la época). Mapas de más de 8 MB requieren 1.27+.
- 1.28.5 sube el límite de tamaño y mantiene la estética clásica.

## La alternativa documentada: 1.28.5

**1.28.5** (2017) es la última versión razonablemente "clásica" (pre-1.29,
que rompió compatibilidad con muchos mapas y bots):

- A favor: mapas más grandes (límite de 128 MB), fixes de estabilidad en
  máquinas modernas, widescreen razonable.
- En contra: los clientes 1.28 no pueden jugar con clientes 1.26 (versión de
  protocolo distinta); algunos mapas/sistemas viejos se comportan distinto;
  la escena "clásica" de la que salen nuestros mapas vivió en 1.26.

## Cómo se cambia de versión (diseño por variables)

Todo lo dependiente de versión está detrás de variables; migrar a 1.28.5 es:

1. `.env`: `WC3_WAR3_VERSION=28`.
2. Reemplazar los archivos de `/opt/wc3/mpq/` por los de la instalación
   1.28.5 (el bot calcula `exeversion/exeversionhash` desde ahí).
3. `make render-config && sudo systemctl restart pvpgn wc3-hostbot@1 wc3-hostbot@2`.
4. Verificar que el `versioncheck.json` de PvPGN tenga la entrada de 1.28.5
   (el de fábrica trae `W3XP_128A`... **TODO(verificar): confirmar el tag
   exacto para 1.28.5 en el archivo instalado antes de migrar**).
5. Redistribuir a los jugadores el cliente 1.28.5 (todos migran o nadie).

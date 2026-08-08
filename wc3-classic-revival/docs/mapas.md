# Protocolo de validación de mapas

Objetivo: que cada mapa del registry pase de `pendiente` a `validado` (o
`descartado`) con evidencia real, no con "debería andar". El registry
(`maps/registry.yaml`) es la fuente de verdad; este documento es el
procedimiento.

## Ciclo de estados

```
pendiente -> descargado -> validado
                      \-> descartado (con nota de por qué)
```

- `pendiente`: sabemos que lo queremos, no tenemos el archivo.
- `descargado`: el .w3x está en `/opt/wc3/maps/` y pasó por inspect-map.py.
- `validado`: pasó TODOS los pasos de abajo.
- `descartado`: no carga en 1.26a / versión inconseguible / reemplazado.

## Paso a paso (por mapa)

1. **Conseguir el archivo correcto.** Verificar contra `aliases` y `notes`
   del registry que sea el linaje correcto (ej.: hay varios "Axe Wars" que no
   son el spinoff de Pudge Wars). Anotar `source_url` en el registry.
2. **Inspección automática:**

   ```bash
   /opt/wc3/venv/bin/python scripts/inspect-map.py "/opt/wc3/maps/ElMapa.w3x" --update-registry --pretty
   ```

   Esto completa `size_mb`, `slots`, `teams` (sin pisar lo editado a mano) y
   sube `status` a `descargado`. Si el mapa está protegido lo dice claro: la
   metadata se carga a mano.
3. **Carga en single player (la prueba del return bug):** abrir el mapa en
   Custom Game single player con un cliente **1.26a** real. Si el mapa no
   aparece en la lista, no carga, o crashea al iniciar → probable return bug
   u otra incompatibilidad 1.24+. Probar otra versión del mapa o descartarlo.
   Anotar el resultado en `notes`.
4. **Tamaño vs 4 MB:** si `size_mb > 4`, marcar en `notes` que va por map
   pack (no se transfiere in-lobby en 1.26a; ver docs/version-1.26a.md).
5. **Alta en el bot:** copiar el .w3x a `/opt/wc3/maps/` y en el canal del
   bot: `!map ElMapa` (el bot indexa el archivo y calcula el hash/CRC con
   StormLib usando common.j/blizzard.j de los MPQ). Si el bot no puede
   calcular el hash, revisar que `/opt/wc3/mpq/War3Patch.mpq` exista.
6. **Prueba de sincronía con dos clientes reales:** hostear con
   `!pub prueba`, entrar con **dos clientes 1.26a desde redes distintas**
   (uno afuera del VPS mínimo), jugar 5-10 minutos. Buscar:
   - que ambos entren al lobby y vean bien los slots/equipos,
   - que la partida arranque para ambos,
   - **desincronización** ("desync"): un jugador ve otra cosa que el otro, o
     el bot reporta jugadores dropeados por desync en el log.
7. **Marcar `validado`** en el registry, con la versión exacta probada en
   `versions_known` y `target_version`.

## Map pack versionado (fase 2)

Los mapas >4 MB (y por comodidad, todos) se distribuyen como pack:

- Nombre: `wc3revival-maps-vNN.zip` (NN incremental; el contenido de un NN
  publicado no se cambia jamás, se publica NN+1).
- Contenido: los .w3x con `status: validado`, con los nombres de archivo
  EXACTOS que usa el bot (el hash tiene que coincidir).
- Destino en el cliente: `Warcraft III/Maps/Download/`.
- El pack se genera en el server y se comparte por fuera (Drive/Mega/etc.);
  no vive en git (copyright + peso).

## Reglas de higiene

- Nunca commitear un .w3x (el .gitignore lo bloquea; validate.sh lo chequea).
- Un mapa = un entry en el registry. Variantes muy distintas (ej. Pudge Wars
  vs Pudge Wars Advanced) son entries separados.
- Todo descarte lleva nota: qué versión se probó, qué falló.

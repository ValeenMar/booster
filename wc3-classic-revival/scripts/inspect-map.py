#!/usr/bin/env python3
"""inspect-map.py — extrae metadata de un mapa .w3x y opcionalmente la
mergea en maps/registry.yaml.

Que lee:
  1. El header HM3W del .w3x (los primeros 512 bytes, FUERA del archivo MPQ):
     nombre del mapa y max jugadores. Funciona incluso con mapas protegidos,
     porque los protectores solo rompen el interior del MPQ.
  2. Si mpyq esta instalado, abre el MPQ embebido (offset 512) y extrae
     war3map.w3i: nombre real, autor, jugadores y fuerzas (equipos).

Si el mapa esta protegido y el w3i no se puede leer, termina con codigo 2 y
un mensaje claro (sin traceback); la metadata del header HM3W igual se
imprime en el JSON de salida.

El parser de w3i esta validado contra .w3i sinteticos (tests/); la validacion
contra mapas reales es parte de la fase 1 del RUNBOOK.

Uso:
    inspect-map.py MAPA.w3x [--update-registry [RUTA_REGISTRY]] [--pretty]

Dependencias: stdlib. Opcionales: mpyq (lectura del MPQ), PyYAML (para
--update-registry). En el VPS viven en el venv /opt/wc3/venv.
"""

import argparse
import io
import json
import struct
import sys
from pathlib import Path

MPQ_MAGIC = b"MPQ\x1a"
HM3W_MAGIC = b"HM3W"


class InspectError(Exception):
    """Error de inspeccion con mensaje apto para humanos."""


def read_cstring(buf: io.BytesIO) -> str:
    """Lee una cadena terminada en NUL."""
    chunks = []
    while True:
        b = buf.read(1)
        if not b:
            raise InspectError("cadena sin terminador NUL (archivo truncado o corrupto)")
        if b == b"\x00":
            break
        chunks.append(b)
    return b"".join(chunks).decode("utf-8", errors="replace")


def parse_hm3w_header(data: bytes) -> dict:
    """Parsea el header HM3W que precede al MPQ en todo .w3x/.w3m.

    Layout: "HM3W" | uint32 desconocido | nombre (cstring) | uint32 flags |
    uint32 max_players.
    """
    if data[:4] != HM3W_MAGIC:
        raise InspectError(
            "el archivo no empieza con el magic HM3W: no parece un mapa de Warcraft III"
        )
    buf = io.BytesIO(data[8:])
    name = read_cstring(buf)
    try:
        flags, max_players = struct.unpack("<II", buf.read(8))
    except struct.error as exc:
        raise InspectError(f"header HM3W truncado: {exc}") from exc
    return {"header_name": name, "header_flags": flags, "header_max_players": max_players}


def parse_w3i(data: bytes) -> dict:
    """Parsea war3map.w3i (formatos 18 = RoC y 25 = TFT).

    Devuelve nombre, autor, descripcion, cantidad de jugadores y de fuerzas
    (equipos). Los formatos > 25 (Reforged / 1.29+) se rechazan explicitamente:
    este proyecto apunta a 1.26a/1.28.5.
    """
    buf = io.BytesIO(data)

    def u32() -> int:
        raw = buf.read(4)
        if len(raw) != 4:
            raise InspectError("war3map.w3i truncado")
        return struct.unpack("<I", raw)[0]

    def f32() -> float:
        raw = buf.read(4)
        if len(raw) != 4:
            raise InspectError("war3map.w3i truncado")
        return struct.unpack("<f", raw)[0]

    fmt = u32()
    if fmt not in (18, 25):
        raise InspectError(
            f"formato de w3i no soportado: {fmt} (soportados: 18=RoC, 25=TFT; "
            "los mapas 1.29+/Reforged quedan fuera del alcance de este proyecto)"
        )
    out = {"w3i_format": fmt}
    u32()  # cantidad de guardados
    u32()  # version del editor
    out["name"] = read_cstring(buf)
    out["author"] = read_cstring(buf)
    out["description"] = read_cstring(buf)
    out["players_recommended"] = read_cstring(buf)
    for _ in range(8):  # limites de camara
        f32()
    for _ in range(4):  # margenes
        u32()
    out["playable_width"] = u32()
    out["playable_height"] = u32()
    u32()  # flags
    buf.read(1)  # tileset (char)

    if fmt == 25:  # TFT
        u32()  # numero de fondo de pantalla de carga
        read_cstring(buf)  # ruta del modelo de pantalla de carga
        read_cstring(buf)  # texto de pantalla de carga
        read_cstring(buf)  # titulo
        read_cstring(buf)  # subtitulo
        u32()  # set de datos del juego
        read_cstring(buf)  # ruta de prologo
        read_cstring(buf)  # texto de prologo
        read_cstring(buf)  # titulo de prologo
        read_cstring(buf)  # subtitulo de prologo
        u32()  # estilo de niebla
        f32()  # niebla z inicial
        f32()  # niebla z final
        f32()  # densidad de niebla
        buf.read(4)  # color de niebla RGBA
        u32()  # id de clima
        read_cstring(buf)  # ambiente de sonido
        buf.read(1)  # tileset de luz (char)
        buf.read(4)  # color de agua RGBA
    else:  # 18, RoC
        u32()  # numero de fondo de campania
        read_cstring(buf)  # texto de pantalla de carga
        read_cstring(buf)  # titulo
        read_cstring(buf)  # subtitulo
        u32()  # numero de pantalla de carga
        read_cstring(buf)  # texto de prologo
        read_cstring(buf)  # titulo de prologo
        read_cstring(buf)  # subtitulo de prologo

    num_players = u32()
    out["slots"] = num_players
    for _ in range(num_players):
        u32()  # numero interno del jugador
        u32()  # tipo (humano/computadora/neutral/rescatable)
        u32()  # raza
        u32()  # posicion inicial fija
        read_cstring(buf)  # nombre del jugador
        f32()  # start x
        f32()  # start y
        u32()  # prioridades de aliados (low)
        u32()  # prioridades de aliados (high)
    num_forces = u32()
    out["teams"] = num_forces
    return out


def extract_w3i(map_path: Path) -> bytes:
    """Abre el MPQ embebido en el .w3x y extrae war3map.w3i."""
    try:
        import mpyq
    except ImportError as exc:
        raise InspectError(
            "mpyq no esta instalado; sin el solo se lee el header HM3W. "
            "Instalar con: /opt/wc3/venv/bin/pip install mpyq"
        ) from exc

    raw = map_path.read_bytes()
    # El MPQ arranca tipicamente en offset 512; buscamos el magic por las dudas.
    off = raw.find(MPQ_MAGIC)
    if off < 0:
        raise InspectError("no se encontro un archivo MPQ dentro del mapa")
    try:
        archive = mpyq.MPQArchive(io.BytesIO(raw[off:]), listfile=False)
        data = archive.read_file("war3map.w3i")
    except Exception as exc:  # mpyq tira errores variados con MPQ rotos
        raise InspectError(
            f"no se pudo leer el MPQ del mapa (probablemente protegido): {exc}"
        ) from exc
    if not data:
        raise InspectError(
            "el mapa no expone war3map.w3i: esta protegido. "
            "Se puede usar igual (el bot calcula el hash con StormLib), pero la "
            "metadata hay que cargarla a mano en el registry."
        )
    return data


def inspect(map_path: Path) -> tuple[dict, "InspectError | None"]:
    """Devuelve (metadata, error_de_w3i). El error es None si todo se leyo."""
    raw_head = map_path.read_bytes()[:512]
    meta = {
        "file": map_path.name,
        "size_bytes": map_path.stat().st_size,
        "size_mb": round(map_path.stat().st_size / (1024 * 1024), 2),
    }
    meta.update(parse_hm3w_header(raw_head))

    w3i_error = None
    try:
        meta.update(parse_w3i(extract_w3i(map_path)))
    except InspectError as exc:
        w3i_error = exc
    return meta, w3i_error


def normalize(s: str) -> str:
    return "".join(c for c in s.lower() if c.isalnum())


def update_registry(registry_path: Path, meta: dict) -> str:
    """Mergea la metadata en registry.yaml sin pisar campos editados a mano.

    Regla de merge: solo se escriben campos cuyo valor actual es null o no
    existe. Excepcion documentada: status pasa de "pendiente" a "descargado".
    El match es por nombre o alias, normalizado (sin mayusculas ni simbolos).
    """
    try:
        import yaml
    except ImportError as exc:
        raise InspectError(
            "PyYAML no esta instalado; --update-registry lo necesita. "
            "Instalar con: /opt/wc3/venv/bin/pip install pyyaml"
        ) from exc

    doc = yaml.safe_load(registry_path.read_text(encoding="utf-8"))
    candidates = {normalize(meta.get("name") or ""), normalize(meta["header_name"]),
                  normalize(Path(meta["file"]).stem)}
    candidates.discard("")

    target = None
    for entry in doc["maps"]:
        names = {normalize(entry["name"])} | {normalize(a) for a in entry.get("aliases") or []}
        if names & candidates:
            target = entry
            break
    if target is None:
        raise InspectError(
            f"ningun mapa del registry matchea '{meta['header_name']}' "
            f"(archivo {meta['file']}). Agregalo a mano o sumale un alias."
        )

    updates = {
        "size_mb": meta.get("size_mb"),
        "slots": meta.get("slots"),
        "teams": meta.get("teams"),
    }
    changed = []
    for key, value in updates.items():
        if value is not None and target.get(key) is None:
            target[key] = value
            changed.append(key)
    if target.get("status") == "pendiente":
        target["status"] = "descargado"
        changed.append("status")

    if changed:
        registry_path.write_text(
            yaml.safe_dump(doc, allow_unicode=True, sort_keys=False, width=100),
            encoding="utf-8",
        )
    return f"registry: entrada '{target['name']}' -> campos actualizados: {changed or 'ninguno'}"


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("map", type=Path, help="ruta al .w3x")
    parser.add_argument(
        "--update-registry",
        nargs="?",
        const=Path(__file__).resolve().parent.parent / "maps" / "registry.yaml",
        type=Path,
        metavar="REGISTRY",
        help="mergear la metadata en registry.yaml (por defecto el del repo)",
    )
    parser.add_argument("--pretty", action="store_true", help="JSON indentado")
    args = parser.parse_args(argv)

    if not args.map.is_file():
        print(f"error: no existe {args.map}", file=sys.stderr)
        return 1

    try:
        meta, w3i_error = inspect(args.map)
    except InspectError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(meta, ensure_ascii=False, indent=2 if args.pretty else None))

    if args.update_registry:
        try:
            print(update_registry(args.update_registry, meta), file=sys.stderr)
        except InspectError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1

    if w3i_error is not None:
        print(f"aviso: {w3i_error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

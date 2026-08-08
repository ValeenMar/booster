#!/usr/bin/env bash
# ============================================================================
# validate.sh — valida el repo entero EN SECO: sin VPS, sin archivos del juego
#   - shellcheck de todos los .sh
#   - systemd-analyze verify de las unidades (si systemd esta disponible)
#   - registry.yaml contra maps/schema.json
#   - render de templates con .env.example (no debe quedar ${WC3_*} vivo)
#   - tests de inspect-map.py
#
# Uso: ./scripts/validate.sh   (tambien: make validate)
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_DIR   # los sub-shells bash -c lo leen del entorno
FAILURES=0

check() { # check <nombre> <comando...>
    local name="$1"; shift
    if "$@"; then
        printf '  \e[32mOK\e[0m   %s\n' "${name}"
    else
        printf '  \e[31mFAIL\e[0m %s\n' "${name}"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "== shellcheck =="
for sh in "${REPO_DIR}"/install/*.sh "${REPO_DIR}"/scripts/*.sh; do
    check "shellcheck $(basename "${sh}")" shellcheck "${sh}"
done

echo "== systemd =="
if command -v systemd-analyze >/dev/null; then
    # verify exige que las unidades esten en un directorio de busqueda: las
    # copiamos a un dir temporal. Ademas exige que ExecStart y
    # WorkingDirectory EXISTAN; en la validacion en seco (sin /opt/wc3) los
    # stubbeamos SOLO en la copia temporal, para seguir verificando sintaxis
    # y opciones de las unidades reales.
    tmpunits="$(mktemp -d)"
    cp "${REPO_DIR}"/systemd/*.service "${tmpunits}/"
    if [[ ! -x /opt/wc3/hostbot/aura++ ]]; then
        sed -i 's|^ExecStart=/opt/wc3/hostbot/aura++|ExecStart=/bin/true|' \
            "${tmpunits}/wc3-hostbot@.service"
        echo "  (aura++ no instalado: ExecStart stubbeado solo para el verify)"
    fi
    if [[ ! -d /opt/wc3/hostbot/instances/1 ]]; then
        sed -i 's|^WorkingDirectory=.*|WorkingDirectory=/tmp|' \
            "${tmpunits}/wc3-hostbot@.service"
    fi
    if [[ ! -x /opt/wc3/pvpgn/sbin/bnetd ]]; then
        sed -i 's|^ExecStart=/opt/wc3/pvpgn/sbin/bnetd|ExecStart=/bin/true|' \
            "${tmpunits}/pvpgn.service"
        echo "  (bnetd no instalado: ExecStart stubbeado solo para el verify)"
    fi
    # la unidad instanciada se verifica con una instancia concreta
    for unit in pvpgn.service wc3-hostbot@1.service; do
        check "systemd-analyze verify ${unit}" \
            systemd-analyze verify --recursive-errors=no "${tmpunits}/${unit}"
    done
    rm -rf "${tmpunits}"
else
    echo "  SKIP systemd-analyze no disponible en este entorno"
fi

echo "== registry vs schema =="
check "registry.yaml valida contra schema.json" python3 - <<EOF
import json, sys
try:
    import yaml, jsonschema
except ImportError as exc:
    sys.exit(f"falta dependencia: {exc} (apt install python3-yaml python3-jsonschema)")
schema = json.load(open("${REPO_DIR}/maps/schema.json"))
doc = yaml.safe_load(open("${REPO_DIR}/maps/registry.yaml"))
jsonschema.validate(doc, schema)
assert len(doc["maps"]) >= 21, f"se esperan >= 21 mapas, hay {len(doc['maps'])}"
EOF

echo "== render en seco de templates =="
# shellcheck disable=SC2016  # el script hijo expande sus propias variables
check "templates renderizan con .env.example sin placeholders vivos" bash -c '
    set -euo pipefail
    repo="${REPO_DIR}"
    set -a; source "${repo}/.env.example"; set +a
    subst=""
    while IFS= read -r v; do subst+="\${${v}} "; done < <(compgen -v | grep "^WC3_")
    for tpl in "${repo}"/config/pvpgn/*.tpl; do
        out="$(envsubst "${subst}" < "${tpl}")"
        if grep -q "\${WC3_" <<<"${out}"; then
            echo "placeholder sin resolver en ${tpl}" >&2; exit 1
        fi
    done
    # hostbot: base + cada instancia
    for inst in "${repo}"/config/hostbot/instance-*.env; do
        ( set -a; source "${inst}"; set +a
          out="$(envsubst "${subst}" < "${repo}/config/hostbot/aura.cfg.tpl")"
          if grep -q "\${WC3_" <<<"${out}"; then
              echo "placeholder sin resolver para ${inst}" >&2; exit 1
          fi )
    done
'

echo "== puertos de instancias sin colisiones =="
# shellcheck disable=SC2016  # el script hijo expande sus propias variables
check "hostport/reconnectport unicos entre instancias" bash -c '
    set -euo pipefail
    repo="${REPO_DIR}"
    ports="$(grep -h "^WC3_BOT_\(HOST\|RECONNECT\)PORT=" "${repo}"/config/hostbot/instance-*.env | cut -d= -f2)"
    dup="$(sort <<<"${ports}" | uniq -d)"
    if [[ -n "${dup}" ]]; then echo "puertos duplicados: ${dup}" >&2; exit 1; fi
'

echo "== tests de inspect-map.py =="
check "unittest tests/" python3 -m unittest discover -s "${REPO_DIR}/tests" -q

echo "== copyright: nada de material del juego commiteado =="
# shellcheck disable=SC2016  # el script hijo expande sus propias variables
check "sin .w3x/.mpq/.exe/.dll trackeados en git" bash -c '
    cd "${REPO_DIR}"
    if git ls-files 2>/dev/null | grep -iE "\.(w3x|w3m|mpq|exe|dll)$"; then
        exit 1
    fi
    exit 0
'

echo
if [[ "${FAILURES}" -eq 0 ]]; then
    echo "validate: todo en verde"
else
    echo "validate: ${FAILURES} chequeos fallaron" >&2
    exit 1
fi

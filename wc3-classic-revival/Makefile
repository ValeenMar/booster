# ============================================================================
# wc3-classic-revival — targets de operacion
# Los targets que tocan el sistema (bootstrap/build/install/render) piden sudo
# y solo tienen sentido en el VPS; validate y map-scan corren en cualquier lado.
# ============================================================================

.PHONY: help bootstrap build install render-config validate map-scan test backup

help:
	@echo "Targets:"
	@echo "  bootstrap      prepara un Ubuntu 24.04 limpio (sudo)"
	@echo "  build          compila e instala PvPGN y Aura (sudo)"
	@echo "  install        bootstrap + build + mysql (sudo)"
	@echo "  render-config  renderiza templates + .env -> configs (sudo)"
	@echo "  validate       valida todo en seco (sin VPS ni juego)"
	@echo "  test           tests de inspect-map.py"
	@echo "  map-scan       inspecciona todos los .w3x de maps/ y actualiza el registry"
	@echo "  backup         dump de MySQL + configs a tar fechado (sudo)"

bootstrap:
	sudo ./install/00-bootstrap-vps.sh

build:
	sudo ./install/10-build-pvpgn.sh
	sudo ./install/20-build-hostbot.sh

install: bootstrap build
	sudo ./install/30-setup-mysql.sh

render-config:
	sudo ./install/40-render-configs.sh

validate:
	./scripts/validate.sh

test:
	python3 -m unittest discover -s tests -v

# Usa el venv del VPS si existe (tiene mpyq); si no, el python del sistema
# (solo header HM3W). El || true: un mapa protegido (exit 2) no corta el scan.
map-scan:
	@PY=/opt/wc3/venv/bin/python; [ -x $$PY ] || PY=python3; \
	found=0; \
	for m in maps/*.w3x /opt/wc3/maps/*.w3x; do \
		[ -f "$$m" ] || continue; \
		found=1; \
		echo "== $$m"; \
		$$PY scripts/inspect-map.py "$$m" --update-registry --pretty || true; \
	done; \
	[ $$found -eq 1 ] || echo "no hay .w3x en maps/ ni /opt/wc3/maps/"

backup:
	sudo ./scripts/backup.sh

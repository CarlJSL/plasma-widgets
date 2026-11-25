#!/usr/bin/env bash
# Copia lo común (shared/) a cada widget: Plasma empaqueta cada widget por separado y no puede leer fuera de su carpeta.
# Se corre solo desde los install.sh; las copias van en git para que cada widget funcione tal cual.
set -euo pipefail
cd "$(dirname "$0")/.."
for pkg in pr-tracker/plasmoid pr-tracker/plasmoid-tickets pr-tracker/plasmoid-links flujo-tracker/plasmoid kitty-historial/plasmoid; do
  install -Dm644 shared/CompactIcon.qml "$pkg/contents/ui/CompactIcon.qml"
  mkdir -p "$pkg/contents/ui/icons"
  install -m644 shared/icons/*.svg "$pkg/contents/ui/icons/"
done

#!/usr/bin/env bash
# Instala todos los widgets, o solo los que nombres:
#   ./install.sh                      -> todos
#   ./install.sh pr-tracker kitty-historial
set -euo pipefail
cd "$(dirname "$0")"
ALL=(pr-tracker flujo-tracker kitty-historial)
LIST=("$@"); [ ${#LIST[@]} -eq 0 ] && LIST=("${ALL[@]}")
for w in "${LIST[@]}"; do
  [ -x "$w/install.sh" ] || { echo "No existe el widget «$w». Disponibles: ${ALL[*]}" >&2; exit 1; }
  echo "== $w"
  "$w/install.sh"
done

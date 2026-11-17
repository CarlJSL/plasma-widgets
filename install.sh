#!/usr/bin/env bash
# Instala los scripts y los widgets de Plasma. Luego: clic derecho en el panel > Añadir widgets > "Mis PRs" / "Mis tickets".
set -euo pipefail
cd "$(dirname "$0")"
install -Dm755 bin/my-prs.py "$HOME/.local/bin/my-prs"
install -Dm755 bin/my-tickets.py "$HOME/.local/bin/my-tickets"
for dir in plasmoid plasmoid-tickets; do
  kpackagetool6 -t Plasma/Applet -i "$dir" 2>/dev/null || kpackagetool6 -t Plasma/Applet -u "$dir"
done
echo "Listo. Si no aparecen los widgets: kquitapp6 plasmashell && kstart plasmashell"

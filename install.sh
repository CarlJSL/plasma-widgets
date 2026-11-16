#!/usr/bin/env bash
# Instala el script y el widget de Plasma. Luego: clic derecho en el panel > Añadir widgets > "Mis PRs".
set -euo pipefail
cd "$(dirname "$0")"
install -Dm755 bin/my-prs.py "$HOME/.local/bin/my-prs"
kpackagetool6 -t Plasma/Applet -i plasmoid 2>/dev/null || kpackagetool6 -t Plasma/Applet -u plasmoid
echo "Listo. Si no aparece el widget: kquitapp6 plasmashell && kstart plasmashell"

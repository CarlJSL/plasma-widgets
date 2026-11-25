#!/usr/bin/env bash
# Instala el script, el widget de Plasma y el atajo `t` de fish.
# Luego: clic derecho en el panel > Añadir widgets > "Flujo de tickets".
set -euo pipefail
cd "$(dirname "$0")"
install -Dm755 bin/flujo.py "$HOME/.local/bin/flujo"
install -Dm644 fish/t.fish "$HOME/.config/fish/functions/t.fish"
kpackagetool6 -t Plasma/Applet -i plasmoid 2>/dev/null || kpackagetool6 -t Plasma/Applet -u plasmoid
echo "Listo. Si no aparece el widget: kquitapp6 plasmashell && kstart plasmashell"

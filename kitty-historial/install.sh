#!/usr/bin/env bash
# Instala el CLI, el gancho de kitty y el widget. Luego reinicia kitty (las terminales ya abiertas no se anotan).
set -euo pipefail
cd "$(dirname "$0")"
"../tools/sync-shared.sh"
install -Dm755 bin/kitty-historial "$HOME/.local/bin/kitty-historial"
install -Dm644 watcher.py "$HOME/.config/kitty/historial_watcher.py"
CONF="$HOME/.config/kitty/kitty.conf"
if ! grep -q "historial_watcher.py" "$CONF" 2>/dev/null; then
  printf '\n# Historial de terminales (kitty-historial)\nwatcher historial_watcher.py\n' >> "$CONF"
  echo "Agregué 'watcher historial_watcher.py' a $CONF"
fi
kpackagetool6 -t Plasma/Applet -i plasmoid 2>/dev/null || kpackagetool6 -t Plasma/Applet -u plasmoid
echo "Listo. Reinicia kitty y añade el widget «Historial de terminales» (clic derecho en el panel > Añadir widgets)."

# kitty-historial

Widget de Plasma que muestra el historial de terminales de kitty: carpeta, rama de git, hora, duración y comandos de cada una, más una pestaña con todos los comandos. Desde cada fila se copia la carpeta o el comando y se abre una terminal nueva en esa carpeta.

## Cómo funciona

- `watcher.py` es un gancho de kitty (opción `watcher`). Anota en `~/.local/share/kitty-historial/events.jsonl` cuándo se abre y se cierra cada ventana, sus cambios de carpeta y cada comando (usa la shell integration de kitty).
- `bin/kitty-historial` lee ese registro y lo resume en JSON. Conserva 90 días cuando el archivo pasa de 8 MB.
- `plasmoid/` es el widget.

Solo se anota lo que ocurre desde la instalación: kitty no guarda nada de las terminales ya cerradas. Las terminales que ya estaban abiertas empiezan a anotarse cuando reinicias kitty.

## Instalar

```
./install.sh
```

Agrega `watcher historial_watcher.py` a `~/.config/kitty/kitty.conf` si no está, instala el CLI en `~/.local/bin` y el widget. Después reinicia kitty y añade «Historial de terminales» al panel.

Requiere kitty con `shell_integration enabled` y Plasma 6.

# plasma-widgets

Widgets de KDE Plasma 6 (con sus scripts de apoyo) para el trabajo diario. Cada carpeta es independiente y trae su propio README e `install.sh`.

| Carpeta | Widgets | Para qué |
|---|---|---|
| [`pr-tracker`](pr-tracker/) | Mis PRs, Mis tickets, Mis links | Seguimiento de tus PRs de GitHub (estado, revisados, re-review, conflictos, review con Claude), tus tickets de Jira y tus links guardados |
| [`flujo-tracker`](flujo-tracker/) | Flujo de tickets | En qué fase del flujo de desarrollo está cada ticket y el comando para seguir |
| [`kitty-historial`](kitty-historial/) | Historial de terminales | Terminales de kitty que has abierto, con carpeta, rama, duración y comandos |

## Instalar

```
./install.sh                          # todos
./install.sh pr-tracker kitty-historial   # solo algunos
```

Después, clic derecho en el panel > Añadir widgets. Si no aparecen: `kquitapp6 plasmashell && kstart plasmashell`.

Cada `install.sh` copia los scripts a `~/.local/bin` y registra el widget con `kpackagetool6`. Lo que corre Plasma es esa copia instalada, no la de este repo: tras editar el código, vuelve a correr el instalador y reinicia Plasma.

## Requisitos

Plasma 6, Python 3 y, según el widget, `gh` (pr-tracker, flujo-tracker) o kitty con `shell_integration` (kitty-historial).

## Licencia

MIT, ver `LICENSE`.

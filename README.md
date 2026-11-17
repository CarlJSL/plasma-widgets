# pr-tracker

Widget de **KDE Plasma 6** que muestra en la barra tus **pull requests abiertos** de GitHub con su estado, para no perder links ni saber cuál es cuál. Solo PRs abiertos: los mergeados desaparecen solos.

## Qué hace

- Ícono de GitHub en el panel con un contador de PRs abiertos (rojo si alguno requiere atención, azul si no).
- Al hacer clic se abre la lista, agrupada por repo, con `#número título` y `rama → base`. Clic en una fila abre el PR en el navegador.
- Muestra los PRs de **todas** las cuentas logueadas en `gh` (no solo la activa); si hay más de una, cada fila indica `@cuenta`.
- Botón **Copiar resumen**: copia al portapapeles un texto para el revisor o el TL, con los PRs agrupados (necesitan review, esperando re-review, aprobados, CI en curso, por atender, drafts) y sus links.
- Se actualiza solo cada 2,5 minutos; hay botón para forzar la consulta.
- Si una cuenta falla (token vencido, sin red), las demás siguen mostrándose; el error sale en rojo en la lista, en el tooltip y como un punto ámbar `!` en el ícono de la barra.
- Notificación de escritorio cuando un PR **cambia** a observado, con conflictos, CI fallando o aprobado (no avisa en la primera carga ni repite).
- Ordenado por fecha de creación, más reciente primero, agrupado por repo.

### Estados

| Estado | Significado |
|---|---|
| Draft | PR en borrador |
| Esperando review | Sin decisión todavía |
| Esperando re-review | Te observaron, pero subiste commits después de la observación |
| Observado | Cambios solicitados sobre el último commit |
| CI en curso | Los checks/tests del último commit siguen corriendo (azul). Tiene prioridad sobre «Aprobado» y «Esperando review» |
| Aprobado | Aprobado por los revisores |
| Conflictos | No se puede mergear por conflictos |
| CI fallando | Los checks del último commit fallan |

Prioridad cuando hay varios: draft → observado vigente → conflictos → CI fallando → CI en curso → esperando re-review → aprobado → esperando review.

## Requisitos

- KDE Plasma 6 (`kpackagetool6`)
- [`gh`](https://cli.github.com/) autenticado (`gh auth login`)
- `python3`
- `notify-send` (libnotify) para las notificaciones

## Instalación paso a paso

1. **Instala las dependencias** (ejemplo en Arch/CachyOS; en otras distros usa su gestor):
   ```sh
   sudo pacman -S github-cli python libnotify
   ```
2. **Autentica `gh`** con las cuentas cuyos PRs quieres ver (repite `gh auth login` por cada una):
   ```sh
   gh auth login
   gh auth status   # verifica que la cuenta activa es la correcta
   ```
3. **Clona el repo:**
   ```sh
   git clone https://github.com/CarlJSL/pr-tracker.git
   cd pr-tracker
   ```
4. **Prueba el script** antes de instalar el widget; debe imprimir tus PRs en JSON:
   ```sh
   python3 bin/my-prs.py | python3 -m json.tool
   ```
   Si `error` no es `null`, revisa el paso 2.
5. **Instala:**
   ```sh
   ./install.sh
   ```
   Copia el script a `~/.local/bin/my-prs` e instala el widget en `~/.local/share/plasma/plasmoids/`.
6. **Recarga Plasma** para que detecte el widget:
   ```sh
   kquitapp6 plasmashell && kstart plasmashell
   ```
7. **Añádelo al panel:** clic derecho en el panel → **Añadir widgets** → busca **Mis PRs** → arrástralo a la barra.

### Actualizar o desinstalar

- Después de un `git pull` o de editar el código: `./install.sh` y reinicia Plasma (paso 6).
- Desinstalar: `kpackagetool6 -t Plasma/Applet -r io.personal.prtracker && rm ~/.local/bin/my-prs`.

### Problemas comunes

| Síntoma | Causa y solución |
|---|---|
| El widget no aparece en la lista | Reinicia Plasma (paso 6). |
| Dice «Sin PRs abiertos» y tienes PRs | La cuenta con los PRs no está en `gh`: `gh auth login` con esa cuenta (`gh auth status` lista las logueadas). |
| Muestra un error en rojo | Corre el paso 4 en la terminal para ver el mensaje real. |
| No llegan notificaciones | Falta `libnotify` (`notify-send`). |
| Cambié el QML y no se ve | Plasma cachea el QML: `./install.sh` y reinicia Plasma. |

## Cómo funciona

- `bin/my-prs.py` lista las cuentas de `gh` y, por cada una, hace **una** consulta GraphQL con `gh api graphql` usando su token (`is:pr is:open author:@me`) y devuelve JSON con estado de review, CI y mergeabilidad. Se puede usar solo desde la terminal: `my-prs | jq`.
- `plasmoid/` es el widget QML. Ejecuta el script con el motor `executable` de Plasma5Support y pinta el resultado.
- Un PR cuenta como «Observado» solo si el review de cambios solicitados es sobre el commit actual (`headRefOid`); si subiste commits después, pasa a re-review.

## Personalizar

En `plasmoid/contents/ui/main.qml`:

- Intervalo de refresco: `interval: 150000` (ms).
- Colores del contador: línea con `"#e5484d"` / `"#2f81f7"`.
- Qué estados notifican: `notifyOn`.

Para limitar a una org, agrega `org:MI_ORG` a la búsqueda en `bin/my-prs.py`.

## Licencia

MIT

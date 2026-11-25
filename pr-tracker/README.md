# pr-tracker

Widgets de **KDE Plasma 6** para el día a día de desarrollo: **Mis PRs** (tus pull requests abiertos de GitHub con su estado, para no perder links ni saber cuál es cuál), **Mis tickets** (Jira, por columna del tablero, con bloqueos) y **Mis links** (links guardados con acceso rápido).

## Qué hace

- Ícono de GitHub en el panel con un contador de PRs abiertos (rojo si alguno requiere atención, azul si no) y, abajo a la izquierda, un contador ámbar con lo que **depende de ti**: PRs que te piden review + PRs en seguimiento ya mergeados.
- Al hacer clic se abre el panel con tres pestañas:
  - **Mis PRs:** tus PRs abiertos, agrupados por repo, con `#número título`, estado, ticket de Jira (si está configurado) y `rama → base`.
  - Los PRs de un mismo **cambio** (por ejemplo front + back) se agrupan en una tarjeta con avisos: «front aprobado, pero back observado», «front ya se mergeó; falta back» o «todos aprobados: se pueden mergear juntos». Se agrupan por el mismo ticket, o por un par `st-X`/`api-X` con el mismo título (sin «(app)»/«(api)»). Los desalineados también mandan notificación.
  - **Para revisar:** PRs de otros que te pidieron review, con su antigüedad y cuántos archivos llevas marcados como «Viewed» en GitHub (`visto 4/12`). Al pasar el mouse, dos botones para **leer el código** en vez de solo aprobar (ver «Revisar el código»).
  - **Mergeados:** tus PRs mergeados en los últimos `mergedDays` días (5 por defecto), con cuándo se mergearon, a qué rama y el estado de su ticket.
  - **Para revisar** también incluye los PRs que ya revisaste y recibieron commits después de tu review (con la etiqueta «Commits nuevos tras tu review»): GitHub no te los vuelve a pedir solo.
  - **Quién ya revisó:** cada PR muestra etiquetas con los revisores: `✓ @alguien` aprobó, `✗` pidió cambios, `•` comentó, y `○ alguien pendiente` si se le pidió review y no ha respondido. Una etiqueta atenuada con «viejo» es un review anterior a los últimos commits, que ya no cuenta; al pasar el mouse dice cuándo fue.
    En esos PRs los botones trabajan solo con lo que cambió desde tu review: el diff y los archivos que se abren son los de `<tu commit>..HEAD` (sin lo que solo entró de la base por un merge), y la sesión de Claude arranca como re-revisión con ese rango.
  - **Revisados:** PRs de otras personas que ya revisaste (aprobaste, pediste cambios o comentaste) en los últimos `reviewedDays` días (14 por defecto). Muestra tu veredicto, si el PR ya se mergeó y si hay commits nuevos desde tu review.
  - **Seguimiento:** PRs ajenos de los que dependes. Pegas el link y una nota («cuando se mergee abro el mío») y el widget te avisa con una notificación cuando se hace merge o se cierra. Queda en la lista hasta que lo quites.
- Clic en una fila abre el PR. Al pasar el mouse aparecen acciones: copiar link, abrir los checks (CI) y, en tus PRs observados o en re-review, **pedir re-review** a quienes ya revisaron.
- **Estancados:** un PR esperando review sin actividad por `staleDays` o más (por defecto 2) se marca «sin movimiento N d» y recibes **un recordatorio diario** (después de las 9:00).
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

## Widget «Mis tickets» (Jira)

Segundo widget, independiente del de PRs, que usa la misma configuración de Jira (ver «Configuración opcional»):

- Tus tickets asignados y abiertos, ordenados **según el tablero de Jira**: por tablero y, dentro de cada uno, por columna (en el orden en que aparecen en el board), con tipo, prioridad y antigüedad. Por cada proyecto elige el tablero que cubre más de tus estados (y, a igualdad, el de más columnas); se puede fijar con `"boards": {"IN": 35}` en `config.json`. La configuración de tableros se cachea un día.
- Backlog y «por hacer» ocultos por defecto (casilla para mostrarlos).
- Marca como «sin movimiento» los que están en curso y llevan `ticketStaleDays` o más días sin actualizarse (3 por defecto); el contador del ícono se pone rojo si hay alguno.
- Botón **Copiar resumen** con tus tickets activos por estado, para el daily.
- **Bloqueados:** pasa el mouse sobre un ticket y usa el candado para marcar «no puedo avanzar este hasta terminar ese otro» (con una nota). El formulario trae un **buscador**: escribes la clave (`IN-1700`) o palabras del título y busca en todo Jira (tus tickets salen al instante, el resto tras ~0,4 s); eliges el resultado con un clic o con Enter para el primero. La pestaña **Bloqueados** lista cada dependencia con el estado actual del ticket que bloquea; cuando ese ticket se termina, llega una notificación («Ya puedes avanzar X») y el ícono muestra un contador verde. El ticket bloqueante puede ser de cualquiera. Se guarda en `~/.local/share/pr-tracker/blocks.json` (no escribe nada en Jira). También entra en «Copiar resumen».
- **Buscador de la lista:** arriba de los tickets. Escribes una clave o palabras del título: filtra tus tickets al instante y, tras ~0,4 s, agrega en «Jira › Otros resultados» los tickets del resto de Jira (también con sus botones).
- **Worktrees por ticket:** si en `reviewDir` (por defecto `~/Proyectos/worktrees`) hay carpetas con el formato `<repo>-<CLAVE>[-sufijo]` (por ejemplo `api-investor-io-IN-1588-tanda2`), la fila muestra la etiqueta «worktree N» y un botón de carpeta que lista cada uno con dos acciones: **Abrir** (VS Code y una terminal con Claude en ese worktree) y **copiar el comando** `wt <repo> <nombre>` (la función de fish del apartado «Revisar el código»). Si el ticket no tiene worktree, el botón no aparece.
- Notificación cuando te asignan un ticket nuevo.
- Refresco cada 5 minutos. Clic en una fila abre el ticket.

Requiere `jiraSite` y `jiraEnv` en `config.json`. Se añade al panel como **Mis tickets**.

## Widget «Mis links»

Un lanzador de links: guardas los que abres a diario (tableros, dashboards, docs, ambientes) y los abres sin buscar en el navegador.

- **Atajo de teclado:** clic derecho en el ícono → «Configurar Mis links…» → «Atajos de teclado», y asigna una combinación (por ejemplo `Meta+L`) que abre el panel desde cualquier lugar.
- Al abrirse, el cursor ya está en el buscador: escribes parte del título, dominio o grupo, y con **Enter** se abre el primero. **↑/↓** cambian de resultado.
- **Agregar:** botón «Agregar». Pega solo lo que tengas en el portapapeles; el título es opcional (si no, usa el dominio y el último tramo de la ruta) y el grupo también (elige uno existente o escribe uno nuevo).
- Al pasar el mouse sobre un link: copiar o borrar. Se agrupan por «grupo» y quedan ordenados por nombre.
- Se guardan en `~/.local/share/pr-tracker/links.json` (se puede editar a mano); no se envía nada a ningún servicio. Se añade al panel como **Mis links**.

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
   git clone https://github.com/CarlJSL/plasma-widgets.git
   cd plasma-widgets/pr-tracker
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
- Desinstalar: `kpackagetool6 -t Plasma/Applet -r io.personal.prtracker` (y `io.personal.tickettracker`, `io.personal.linkbox` para los otros widgets) y borrar `~/.local/bin/my-prs`, `my-tickets` y `my-links`.

### Problemas comunes

| Síntoma | Causa y solución |
|---|---|
| El widget no aparece en la lista | Reinicia Plasma (paso 6). |
| Dice «Sin PRs abiertos» y tienes PRs | La cuenta con los PRs no está en `gh`: `gh auth login` con esa cuenta (`gh auth status` lista las logueadas). |
| Muestra un error en rojo | Corre el paso 4 en la terminal para ver el mensaje real. |
| No llegan notificaciones | Falta `libnotify` (`notify-send`). |
| Cambié el QML y no se ve | Plasma cachea el QML: `./install.sh` y reinicia Plasma. |

## Cómo funciona

- `bin/my-prs.py` lista las cuentas de `gh` y, por cada una, hace dos consultas GraphQL con `gh api graphql` usando su token (`author:@me` y `review-requested:@me`), más una por cada PR en seguimiento y devuelve JSON con estado de review, CI y mergeabilidad. Se puede usar solo desde la terminal: `my-prs | jq`.
- `plasmoid/` es el widget QML. Ejecuta el script con el motor `executable` de Plasma5Support y pinta el resultado.
- Un PR cuenta como «Observado» solo si el review de cambios solicitados es sobre el commit actual (`headRefOid`); si subiste commits después, pasa a re-review.

## Revisar el código (no solo delegarlo)

Pensado para dos casos: leer el PR de otra persona y **entender el código que la IA escribe por ti**. En «Para revisar» y en «Mis PRs», cada PR tiene dos botones al pasar el mouse:

- **VS Code:**
  - En **Para revisar** crea (o actualiza) un worktree del PR y abre solo los archivos que aún no marcaste como vistos, en **orden de lectura**: migraciones, contratos (DTO, entidades, interfaces), controllers y módulos, lógica, tests, estilos y el resto. Lockfiles y snapshots se omiten. Máximo 25 archivos por apertura.
  - En **Mis PRs** abre solo la carpeta del worktree de tu rama, para usar el panel **Control de código fuente** (`Ctrl+Shift+G`). Ahí ves los archivos modificados (`M`) y nuevos (`U`) con su diff lado a lado.
- **Terminal:** abre una terminal con el diff completo (`git diff` con [delta](https://github.com/dandavison/delta)) en el mismo orden de lectura.

Si la rama del PR ya está abierta en uno de tus worktrees (lo normal en tus PRs), se usa ese en vez de crear otro. El clon local se busca por su `remote` dentro de `reposDir`; si no existe, se hace un clon parcial en `~/.cache/pr-tracker/repos`. Los worktrees nuevos quedan en `reviewDir` con el nombre `<repo>-pr<N>`; bórralos con `git worktree remove <ruta>`. Tu clon principal no se toca. La pestaña «Para revisar» solo muestra PRs donde GitHub te asignó como revisor y se oculta si no hay ninguno.

### Code review con IA

Cada PR tiene además un botón con el ícono de visto bueno que abre una **sesión interactiva de Claude Code** en una terminal. Consume tu uso normal de Claude y **no publica nada solo**: el borrador y cada acción externa los apruebas tú.

- **Mis PRs → autorreview:** abre Claude en el worktree de tu rama y ejecuta `selfReviewPrompt` (por defecto `/code-review`, el review integrado de Claude Code) sobre tu cambio, antes de pedir review.
- **Para revisar → code review de otro PR:**
  - Si configuras `harnessDir`, abre Claude **en esa carpeta** con el agente `reviewAgent` (por defecto `review`, de `.claude/agents/`) y le pasa `owner/repo#N` con el link. Pensado para un repo de contexto propio con un agente de review (método, estilo y plantilla del equipo).
  - Sin `harnessDir`, prepara el PR en un worktree y corre `selfReviewPrompt` ahí.

Ejemplo de `config.json`: `"harnessDir": "~/ruta/a/tu/repo-de-contexto"`, `"reviewAgent": "review"`, `"selfReviewPrompt": "/code-review"` (puede ser cualquier skill o prompt tuyo).

### Review en lote (muchos PRs asignados)

En «Para revisar», el botón **Review en lote…** hace una **primera pasada** de code review de varios PRs a la vez, sin abrir una sesión por cada uno. Requiere `harnessDir` (ver arriba).

- Eliges cuántos (los que más llevan esperando van primero) y confirmas. Corre en **segundo plano** con `claude -p` y el agente `reviewAgent`, de a `batchParallel` PRs (3 por defecto).
- **No publica nada.** El lote solo puede leer (git, `gh pr view/diff/checks`, Jira en lectura, CodeGraph); tiene denegados editar archivos, `git push`, `gh pr review/comment/merge/edit/close` y `gh api`. No hace build ni tests (queda en «No verifiqué»), no escribe en Obsidian y no lanza subagentes, para gastar menos.
- Cada PR deja un borrador en `~/.local/share/pr-tracker/reviews/<repo>-pr<N>-<sha>.md`. La fila muestra `en cola`, `revisando…`, `borrador listo` o `review falló`, y el botón de documento abre el borrador en VS Code. El progreso se actualiza cada 15 s y al terminar llega una notificación. Un PR con borrador del mismo commit se salta; si el autor sube cambios, vuelve a quedar pendiente.
- **Para terminar un PR:** botón de code review (la sesión interactiva). Si hay borrador, Claude lo lee, lo verifica contra el código, completa lo que faltó y te lo muestra; publicas solo con tu OK.
- **Cuesta uso de Claude:** cada review es una revisión completa con el agente. Prueba primero con 2 o 3 y revisa la calidad. `batchModel` (por ejemplo `"sonnet"`) lo abarata; `batchTimeoutMin` (30) limita cada review; `batchAddDirs` (`["~/Proyectos"]`) son las carpetas que puede leer.
- `my-prs batch <cuenta> <URL> ...` y `my-prs batch-stop` hacen lo mismo desde la terminal.

### Ver lo que escribe la IA mientras lo escribe

1. **Extensión de Claude Code para VS Code** (`code --install-extension anthropic.claude-code`): cada edición propuesta se abre como diff en el editor, con aceptar o rechazar. En una sesión de terminal, `/ide` la conecta al editor. No apruebes ediciones en bloque si quieres ver cada cambio.
2. **Panel Control de código fuente** (`Ctrl+Shift+G`): lista en vivo de archivos modificados y nuevos mientras Claude trabaja.
3. **[GitLens](https://gitlens.dev)** (`code --install-extension eamodio.gitlens`): para la rama completa contra la base, en `Commits` → `Compare`, con todos los archivos y su diff aunque ya estén en commits.
4. **Hábitos que ayudan:** pedir un plan antes del código, features en pasos chicos con un commit por paso, y escribir en una línea con tus palabras qué hace el PR antes de abrirlo.

VS Code no permite abrir directamente en el panel de cambios desde la línea de comandos; la primera vez en cada carpeta pulsa `Ctrl+Shift+G` y después recuerda la vista.

**Atajo opcional para la terminal (fish):** si abres Claude en un worktree con una función propia, que también abra el editor en esa carpeta:

```fish
function wt --description 'VS Code y Claude en el worktree de un ticket: wt <repo> <KEY>'
    set -l dir ~/Proyectos/worktrees/$argv[1]-$argv[2]
    test -d $dir; or begin; echo "No existe $dir"; return 1; end
    cd $dir; or return 1
    if type -q code
        command code $dir >/dev/null 2>&1 &
        disown
    end
    claude
end
```

## Configuración opcional

Archivo `~/.config/pr-tracker/config.json`:

```json
{
  "staleDays": 2,
  "mergedDays": 5,
  "reviewedDays": 14,
  "ticketStaleDays": 3,
  "boards": { "PROYECTO": 123 },
  "reposDir": "~/Proyectos",
  "reviewDir": "~/Proyectos/worktrees",
  "editor": "code",
  "worktreeCmd": "claude",
  "harnessDir": "~/ruta/a/tu/repo-de-contexto",
  "reviewAgent": "review",
  "selfReviewPrompt": "/code-review",
  "batchParallel": 3,
  "batchModel": "sonnet",
  "batchTimeoutMin": 30,
  "batchAddDirs": ["~/Proyectos"],
  "terminal": "kitty",
  "jiraSite": "tuempresa.atlassian.net",
  "jiraEnv": "~/.config/pr-tracker/jira.env"
}
```

**Jira (opcional):** si `jiraSite` y las credenciales existen, cada PR muestra el estado de su ticket (la clave se toma del título o de la rama, por ejemplo `ABC-123`). Las credenciales van en el archivo `jiraEnv` (por defecto `~/.config/pr-tracker/jira.env`, con `chmod 600`):

```sh
printf 'JIRA_EMAIL=<tu email>\nJIRA_API_TOKEN=<token>\n' > ~/.config/pr-tracker/jira.env
chmod 600 ~/.config/pr-tracker/jira.env
```

El token se genera en [id.atlassian.com → Seguridad → API tokens](https://id.atlassian.com/manage-profile/security/api-tokens). Sin esta configuración, el widget funciona igual, solo sin el dato de Jira.

## CLI

El script también sirve desde la terminal:

```sh
my-tickets block add <KEY> <BLOQUEADOR> [nota]   # KEY espera a BLOQUEADOR
my-tickets block rm <KEY>
my-tickets search <texto o clave>    # busca tickets en Jira (JSON)
my-tickets worktrees                 # worktrees agrupados por clave de ticket (JSON)
my-tickets open-wt <repo> <nombre>   # abre VS Code y una terminal con Claude en <repo>-<nombre>
my-links                              # JSON con los links guardados
my-links add <URL> [título] [grupo]   # guardar un link
my-links rm <ID>                      # borrar un link
my-links move <ID> <GRUPO>            # cambiar de grupo
my-prs | jq                          # JSON con todo
my-prs watch add <URL> [nota]        # seguir un PR ajeno
my-prs watch rm <URL>                # dejar de seguirlo
my-prs rereview <cuenta> <URL>       # pedir re-review a quienes ya revisaron
my-prs codereview <cuenta> <URL> [otros|mio]   # sesión de Claude para code review (ver «Code review con IA»)
my-prs review <cuenta> <URL> [list|code|git|term]   # worktree del PR; list imprime el orden de lectura, git abre solo la carpeta
```

Los PRs en seguimiento se guardan en `~/.local/share/pr-tracker/watch.json`.

## Personalizar

En `plasmoid/contents/ui/main.qml`:

- Intervalo de refresco: `interval: 150000` (ms).
- Colores del contador: línea con `"#e5484d"` / `"#2f81f7"`.
- Qué estados notifican: `notifyOn`.

Para limitar a una org, agrega `org:MI_ORG` a la búsqueda en `bin/my-prs.py`.

## Licencia

MIT

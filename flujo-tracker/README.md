# flujo-tracker

Widget de **KDE Plasma 6** y atajo `t` de fish que muestran **en qué fase del flujo de desarrollo está cada ticket** y dan el comando y la frase para seguir. No ejecutan nada: copian al portapapeles para pegar en la terminal.

## Fases (se detectan solas, sin estado propio)

| Fase | Cómo se detecta | Comando |
|---|---|---|
| 1 · Nuevo | Sin carpeta en Obsidian | `ticket --agent nuevo-ticket` |
| 2 · Análisis y plan | Carpeta existe; `analisis`/`plan` no pasan de la plantilla | `ticket` |
| 3 · Implementación | Hay worktree y no hay PR | `wt <repo> <CLAVE>` |
| 4 · Review | PR abierto (esperando, observado, aprobado) o Jira en CODE REVIEW | `wt …` |
| 5 · QA | Jira en EN QA | `ticket` |
| 6 · Pase a producción | READY TO DEPLOY sin PR abierto, PRD vinculado o el propio PRD | `ticket --agent pase` |
| 7 · Cierre | El PRD vinculado ya está desplegado | `ticket` |

Fuentes: Jira (tickets asignados y pase vinculado), carpetas de `~/Documentos/Notas/yop/Tickets`, `~/Proyectos/worktrees` y `gh` (todas las cuentas). Solo lectura.

## Instalar

```bash
./install.sh   # copia bin/flujo.py a ~/.local/bin/flujo, fish/t.fish a las funciones de fish y registra el widget
```

Luego: clic derecho en el panel > Añadir widgets > «Flujo de tickets».
Jira se toma de `~/.config/pr-tracker/config.json`.

## Tickets cuyo worktree no lleva su clave

`~/.config/flujo-tracker/config.json`:

```json
{ "worktrees": { "IN-1696": ["api-investor-io-IN-1588-tanda2"] } }
```

## Uso

El widget abre en una pantalla de inicio con cuatro acciones:

- **Empezar un ticket nuevo:** escribes la clave y te da el comando (`ticket --agent nuevo-ticket`) y la frase, con los pasos y lo que Claude hará.
- **Crear un pase a producción:** marcas los tickets listos (READY TO DEPLOY sin pase) y te da el comando (`ticket --agent pase`) y la frase con esas claves, más lo que el agente comprobará.
- **Seguir con un ticket:** tus tickets por fase; cada uno con botones visibles de comando y frase.
- **Mis pases a producción:** estado de los PRD que tienes asignados.

Terminal: `t` → elige el ticket → deja la frase en el portapapeles, muestra el comando y abre la sesión.

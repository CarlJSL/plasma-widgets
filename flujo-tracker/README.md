# flujo-tracker

Widget de **KDE Plasma 6** y atajo `t` de fish que muestran **en qué fase del flujo de desarrollo está cada ticket** y dan el comando y la frase para seguir. No ejecutan nada: copian al portapapeles para pegar en la terminal.

## Fases (se detectan solas, sin estado propio)

| Fase | Cómo se detecta | Comando |
|---|---|---|
| 1 · Nuevo | Sin carpeta en Obsidian | `ticket --agent nuevo-ticket` |
| 2 · Análisis y plan | Carpeta existe; `estado_trabajo` en `analisis`/`plan-abierto` (o, sin ese campo, `analisis`/`plan` no pasan de la plantilla) | `ticket` |
| 2 · Plan listo | `estado_trabajo: plan-listo` (o `plan.md` lleno) y sin worktree | `ticket --agent nuevo-ticket` (prepara el entorno) |
| 3 · Implementación | Hay worktree y no hay PR | `wt <repo> <CLAVE>` |
| 4 · Review | PR abierto (esperando, observado) o Jira en CODE REVIEW | `wt …` |
| 4 · Aprobado | PR aprobado o `estado_trabajo: aprobado`: merge, deploy de qas, `pruebas.md` §8 y peso | `wt …` |
| 5 · QA | Jira en EN QA, o `estado_trabajo: validacion-dev` (lo valida el dev en qas) | `ticket --agent evidencia` (evidencia en qas) |
| 6 · Pase a producción | READY TO DEPLOY sin PR abierto, PRD vinculado o el propio PRD | `ticket --agent pase` |
| 7 · Cierre | El PRD vinculado ya está desplegado | `ticket` |

**Contrato con el meta-harness:** `estado_trabajo` y `detalle` del encabezado de `bitacora.md`, con los valores cerrados de su plantilla (`analisis`, `plan-abierto`, `plan-listo`, `implementacion`, `review`, `observado`, `aprobado`, `validacion-dev`, `qa`, `pase`, `cerrado`, `bloqueado`, `descartado`). Un valor fuera de esa lista se ignora y se usa la detección anterior. Avisos en el detalle: «bloqueado: …», «bitácora dice X» si no coincide con lo observado, y «snapshot sin verificar» o «snapshot viejo» si `jira_actualizado` del README falta o es anterior al último cambio en Jira.

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

El widget abre en una pantalla de inicio con cinco acciones:

- **Empezar un ticket nuevo:** escribes la clave y te da el comando (`ticket --agent nuevo-ticket`) y la frase, con los pasos y lo que Claude hará.
- **Crear un pase a producción:** marcas los tickets listos (READY TO DEPLOY sin pase) y te da el comando (`ticket --agent pase`) y la frase con esas claves, más lo que el agente comprobará.
- **Sacar evidencia de un ticket:** escribes la clave (o eliges uno en implementación, review o QA), marcas qas o local y, si quieres, qué mostrar; te da el comando (`ticket --agent evidencia`) y la frase. El agente propone el plan por criterio, captura (pantallas por tamaño o llamadas a la API con datos tapados), te muestra cada imagen y adjunta y comenta en Jira solo con tu OK.
- **Seguir con un ticket:** tus tickets por fase; cada uno con botones visibles de comando y frase.
- **Mis pases a producción:** estado de los PRD que tienes asignados.

Terminal: `t` → elige el ticket → deja la frase en el portapapeles, muestra el comando y abre la sesión.

#!/usr/bin/env python3
"""flujo-tracker: en qué fase del flujo de desarrollo está cada ticket mío y qué sigue.

Solo lectura. Combina cuatro fuentes y no guarda estado propio:
  Jira (tickets asignados, estado y pase PRD vinculado), carpetas de Obsidian, worktrees locales y PRs abiertos (gh).
Imprime JSON; con --list imprime filas TSV para el selector de la terminal (`t`).

Config opcional: ~/.config/flujo-tracker/config.json
  {"worktrees": {"ABC-12": ["mi-repo-rama-larga"]},     # ticket -> worktrees que no llevan su clave
   "org": "MiOrg",                                      # limita la búsqueda de PRs a esa organización de GitHub
   "ticketKeys": "ABC|XYZ|PRD",                         # prefijos de las claves de ticket (por defecto, cualquier PREFIJO-123)
   "releaseChecklist": "la lista «Antes de armar la card» de la skill de pases",
   "auditStep": "autorreview y auditoría de seguridad"}            # textos que van en las frases para Claude
Jira (sitio y credenciales): se toman de ~/.config/pr-tracker/config.json, igual que «Mis tickets».
"""
import base64, json, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from urllib import request as urlrequest

HOME = Path.home()
PRTRACKER = HOME / ".config/pr-tracker/config.json"
CONFIG = HOME / ".config/flujo-tracker/config.json"
OBSIDIAN = HOME / "Documentos/Notas/yop/Tickets"
TEMPLATES = HOME / "Documentos/meta-harness/plantillas/ticket"
WORKTREES = HOME / "Proyectos/worktrees"
JQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
FIELDS = ["summary", "status", "priority", "issuetype", "updated", "project", "issuelinks"]
def _load_cfg():
    try: return json.loads(CONFIG.read_text())
    except Exception: return {}
_CFG = _load_cfg()
ORG = _CFG.get("org", "")
KEYS = _CFG.get("ticketKeys", "[A-Z][A-Z0-9]{1,9}")
RELEASE = _CFG.get("releaseChecklist", "la lista de requisitos del pase")
AUDIT = _CFG.get("auditStep", "autorreview y auditoría de seguridad")
WT_RE = re.compile(r"^(.*?)-((?:" + KEYS + r")-.+)$")
KEY_RE = re.compile(r"\b(?:" + KEYS + r")-\d+\b")

PHASES = {1: "Nuevo", 2: "Análisis y plan", 3: "Implementación", 4: "Review", 5: "QA", 6: "Pase a producción", 7: "Cierre"}
# `estado_trabajo` del encabezado de bitacora.md (valores cerrados de la plantilla del meta-harness) -> fase esperada.
ESTADOS = {"analisis": 2, "plan-abierto": 2, "plan-listo": 2, "implementacion": 3, "review": 4, "observado": 4,
           "aprobado": 4, "validacion-dev": 5, "qa": 5, "pase": 6, "cerrado": 7, "bloqueado": None, "descartado": 7}
FECHA_RE = re.compile(r"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?\s*([+-]\d{2}:?\d{2}|Z)?")


def front(path):
    """Claves `clave: valor` del encabezado YAML de un .md (sin dependencias; ignora comentarios)."""
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return {}
    if not text.startswith("---"):
        return {}
    out = {}
    for line in text.split("\n")[1:]:
        if line.strip() == "---":
            break
        if line.lstrip().startswith("#") or ":" not in line:
            continue
        k, v = line.split(":", 1)
        out[k.strip()] = v.strip().strip("'\"")
    return out


def to_local(text):
    """Primera fecha con hora del texto, en hora local sin zona; None si no hay."""
    m = FECHA_RE.search(text or "")
    if not m:
        return None
    tz = (m.group(3) or "").replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}{tz}")
    except ValueError:
        return None
    return d.astimezone().replace(tzinfo=None) if d.tzinfo else d


def snapshot_state(folder, jira_updated):
    """'pendiente' si el README nunca se verificó contra Jira, 'viejo' si Jira cambió después, '' si está al día."""
    snap = front(folder / "README.md").get("jira_actualizado", "")
    local = to_local(snap)
    if not local:
        return "pendiente"
    remote = to_local(jira_updated)
    return "viejo" if remote and (remote - local).total_seconds() > 60 else ""


def jira_auth():
    cfg = json.loads(PRTRACKER.read_text())
    env = {}
    for line in Path(cfg.get("jiraEnv", "~/.config/pr-tracker/jira.env")).expanduser().read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("'\"")
    token = base64.b64encode(f"{env['JIRA_EMAIL']}:{env['JIRA_API_TOKEN']}".encode()).decode()
    return cfg["jiraSite"], "Basic " + token


def jira_tickets(site, auth):
    tickets, token = [], None
    while True:
        body = {"jql": JQL, "maxResults": 100, "fields": FIELDS}
        if token:
            body["nextPageToken"] = token
        req = urlrequest.Request(f"https://{site}/rest/api/3/search/jql", data=json.dumps(body).encode(),
                                 headers={"Authorization": auth, "Content-Type": "application/json", "Accept": "application/json"})
        with urlrequest.urlopen(req, timeout=25) as r:
            d = json.loads(r.read())
        for i in d["issues"]:
            f = i["fields"]
            prd = None
            for l in f.get("issuelinks") or []:
                other = l.get("outwardIssue") or l.get("inwardIssue")
                if other and other["key"].startswith("PRD-"):
                    prd = {"key": other["key"], "status": other["fields"]["status"]["name"],
                           "cat": other["fields"]["status"]["statusCategory"]["key"]}
            tickets.append({"key": i["key"], "summary": f["summary"], "status": f["status"]["name"],
                            "cat": f["status"]["statusCategory"]["key"], "type": f["issuetype"]["name"],
                            "priority": (f["priority"] or {}).get("name", ""), "updated": f["updated"],
                            "url": f"https://{site}/browse/{i['key']}", "prd": prd})
        token = d.get("nextPageToken")
        if d.get("isLast", True) or not token:
            return tickets


def sh(cmd, env=None):
    import os
    e = dict(os.environ)
    if env:
        e.update(env)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=40, env=e)
    return r.stdout if r.returncode == 0 else ""


def gh_accounts():
    out = sh(["gh", "auth", "status"])
    return re.findall(r"account (\S+)", out)


def open_prs():
    """PRs abiertos míos en la org, de todas las cuentas de gh, con su decisión de review."""
    prs = []
    for acct in gh_accounts():
        tok = sh(["gh", "auth", "token", "--user", acct]).strip()
        if not tok:
            continue
        env = {"GH_TOKEN": tok}
        cmd = ["gh", "search", "prs", "--author", acct, "--state", "open"] + (["--owner", ORG] if ORG else []) + \
              ["--limit", "60", "--json", "number,title,url,repository,body"]
        raw = sh(cmd, env)
        try:
            found = json.loads(raw or "[]")
        except ValueError:
            found = []
        for p in found:
            p["_env"] = env
        prs += found

    def detail(p):
        repo = p["repository"]["nameWithOwner"]
        raw = sh(["gh", "pr", "view", str(p["number"]), "--repo", repo, "--json", "reviewDecision,isDraft,headRefName"], p["_env"])
        try:
            d = json.loads(raw or "{}")
        except ValueError:
            d = {}
        return {"number": p["number"], "repo": repo.split("/")[-1], "url": p["url"], "title": p["title"],
                "title_keys": set(KEY_RE.findall(p["title"] + " " + d.get("headRefName", ""))),
                "body_keys": set(KEY_RE.findall(p.get("body") or "")),
                "decision": d.get("reviewDecision") or "", "draft": bool(d.get("isDraft"))}
    with ThreadPoolExecutor(8) as ex:
        return list(ex.map(detail, prs))


def filled(ticket_dir, name):
    """El análisis o el plan cuentan como hechos si el archivo creció respecto a la plantilla."""
    tpl = TEMPLATES / f"{name}.md"
    base = len(tpl.read_bytes()) if tpl.exists() else 0
    for f in ticket_dir.glob(f"{name}*.md"):
        if f.stat().st_size > base + 300:
            return True
    return False


def worktrees_of(key, folder_text, extra):
    names = set(extra.get(key, []))
    if WORKTREES.is_dir() and key not in extra:
        for d in WORKTREES.iterdir():
            if not d.is_dir() or not WT_RE.match(d.name):
                continue
            if d.name.endswith("-" + key) or ("-" + key + "-") in d.name or d.name in folder_text:
                names.add(d.name)
    out = []
    for n in sorted(names):
        m = WT_RE.match(n)
        if m and (WORKTREES / n).is_dir():
            out.append({"label": m.group(1), "cmd": f"wt {m.group(1)} {m.group(2)}"})
    return out


def pr_matches(p, key, mine, in_review=True):
    """Clave en el título o la rama: PR propio del ticket. En el cuerpo: solo si es una lista de tanda, o sea,
    el cuerpo también nombra la clave del título (un «depende de ABC-120» suelto no cuenta)."""
    if key in p["title_keys"]:
        return True
    if key not in p["body_keys"] or not in_review:
        return False  # una mención en el cuerpo solo asigna el PR a tickets que están en CODE REVIEW
    return not p["title_keys"] or bool(p["title_keys"] & p["body_keys"])


def classify(t, prs, extra, mine):
    key = t["key"]
    folder = OBSIDIAN / key
    folder_text = ""
    if folder.is_dir():
        for f in folder.glob("*.md"):
            try:
                folder_text += f.read_text(errors="ignore")
            except OSError:
                pass
    wts = worktrees_of(key, folder_text, extra)
    my_prs = [p for p in prs if pr_matches(p, key, mine, "review" in t["status"].lower())]
    status = t["status"].lower()
    front_bit = front(folder / "bitacora.md")
    estado = front_bit.get("estado_trabajo", "")
    agent = None
    cmds, detail = [{"label": "meta-harness", "cmd": "ticket"}], ""
    code_cmds = wts or cmds

    if t["type"] == "Pase a producción":
        phase, detail = 6, t["status"]
        phrase = (f"Revisa el pase a prod {key}: lee el ticket, los tickets que implementa, comentarios y aprobaciones, y compáralo con "
                  f"{RELEASE}. Dime qué falta; no publiques nada sin mi OK.")
    elif t["prd"] and t["prd"]["cat"] == "done":
        phase, detail = 7, f"{t['prd']['key']} desplegado"
        phrase = f"El pase {t['prd']['key']} ya está desplegado. Verifica si {key} puede cerrarse (criterios, comentarios, dependencias, flag) y propón comentario y transición sin publicar."
    elif (t["prd"] or "ready" in status or "deploy" in status) and not my_prs:
        phase = 6
        if t["prd"]:
            detail = f"{t['prd']['key']} · {t['prd']['status']}"
            phrase = (f"Revisa el pase a prod {t['prd']['key']} de {key}: estado, aprobaciones y lo que falta según "
                      f"{RELEASE}. No publiques nada sin mi OK.")
        else:
            detail = "sin pase PRD vinculado"
            phrase = (f"Arma el pase a prod de {key}. Revisa {RELEASE}, "
                      "muéstrame el borrador y espera mi OK antes de crear nada en Jira o Slack.")
    elif "qa" in status.replace("code", "") or (estado == "validacion-dev" and not my_prs):
        phase = 5
        if estado == "validacion-dev":
            detail = "validación propia en qas"
            phrase = (f"Retomamos {key}: lo valido yo (pruebas.md §8). Comprueba que el deploy de qas esté en verde, verifica cada caso de «Cómo probarlo» "
                      "en qas, redacta la evidencia sin valores sensibles en jira-borrador.md y propón la transición; nada se publica sin mi OK.")
        else:
            detail = "esperando QA"
            phrase = f"Retomamos {key} en QA: compara lo probado con los criterios de aceptación, la matriz de pruebas y dime qué falta verificar en qas."
    elif my_prs or "review" in status or (estado == "aprobado" and folder.is_dir()):
        phase = 4
        if my_prs:
            p = my_prs[0]
            pr_estado = {"CHANGES_REQUESTED": "observado", "APPROVED": "aprobado"}.get(p["decision"], "esperando review")
            if p["draft"]:
                pr_estado = "borrador"
            detail = f"#{p['number']} {p['repo']} · {pr_estado}" + (f" (+{len(my_prs) - 1} PR más)" if len(my_prs) > 1 else "")
            if pr_estado == "observado":
                phrase = (f"Observado en #{p['number']} ({p['repo']}): lee el review completo, aplica las correcciones en este worktree con tests y volumen medidos, "
                          f"{AUDIT}, y pídeme OK antes del push. Después (cada paso con OK): actualiza la descripción del PR si cambió, "
                          "responde en el PR, pasa el ticket a Code review y registra todo en la bitácora.")
            elif pr_estado == "aprobado":
                phrase = post_merge_phrase(key, f"#{p['number']} ({p['repo']})")
            else:
                phrase = f"Retomamos {key}: revisa #{p['number']} ({p['repo']}) — review, CI, conflictos con qas — y dime qué sigue."
        elif estado == "aprobado":
            detail = "aprobado; falta merge, deploy de qas y validación"
            phrase = post_merge_phrase(key, "su PR")
        else:
            detail = "en CODE REVIEW (sin PR detectado)"
            phrase = f"Retomamos {key}: ubica su PR, revisa review y CI, y dime qué sigue."
        cmds = code_cmds
    elif wts:
        phase, cmds = 3, wts
        detail = "worktree sin PR" + (f" ({len(wts)} repos)" if len(wts) > 1 else "")
        phrase = f"Retomamos {key}: lee README, bitácora y punto de reanudación, compáralo con el estado del worktree y dime qué sigue."
    elif folder.is_dir() and (estado == "plan-listo" or (estado not in ESTADOS and filled(folder, "plan"))):
        phase, detail, agent = 2, "plan listo; falta preparar el entorno", "ticket --agent nuevo-ticket"
        phrase = (f"Retoma {key}: el plan está listo. Comprueba que no quedan decisiones abiertas que cambien repos o alcance y, si es así, "
                  "prepara el entorno (paso 7): worktree por repo desde origin/qas, integrar-proyecto y npm ci --ignore-scripts. "
                  "Muéstrame los comandos y espera mi OK.")
    elif folder.is_dir():
        phase = 2
        if estado == "plan-abierto":
            detail = "plan con decisiones abiertas"
        elif estado == "analisis" or estado not in ESTADOS:
            detail = "análisis hecho; falta el plan" if filled(folder, "analisis") else "carpeta creada; falta el análisis"
        phrase = f"Retomamos {key}: lee README y bitácora, continúa el análisis o el plan en solo lectura y dime qué decisiones faltan."
    else:
        phase, detail = 1, "sin carpeta en Obsidian"
        phrase = (f"Nuevo ticket {key}. Léelo por MCP con descripción, criterios y todos los comentarios. Crea su carpeta en Obsidian "
                  "(vista previa primero), completa el snapshot de Jira y redacta analisis.md en solo lectura.")
    if phase in (1, 2, 5, 6, 7):
        # Fases 1 y 6 (y 2 con el plan listo) abren el agente especializado (`ticket` pasa sus argumentos a claude).
        agent = agent or {1: "ticket --agent nuevo-ticket", 6: "ticket --agent pase"}.get(phase, "ticket")
        cmds = [{"label": "meta-harness", "cmd": agent}]
    nxt = {1: "Empezar el análisis", 2: "Terminar el análisis y el plan", 3: "Seguir con la implementación",
           4: "Ver el review y el CI", 5: "Verificar en qas", 6: "Revisar el pase", 7: "Ver si ya se puede cerrar"}[phase]
    if phase == 4 and "observado" in detail:
        nxt = "Aplicar las correcciones del review"
    elif phase == 4 and "aprobado" in detail:
        nxt = "Merge, deploy de qas y validación"
    elif phase == 2 and "plan listo" in detail:
        nxt = "Preparar el entorno"
    elif phase == 5 and estado == "validacion-dev":
        nxt = "Validar yo en qas"
    elif phase == 6 and t["type"] != "Pase a producción" and not t["prd"]:
        nxt = "Pedir el pase a producción"
    # Avisos: bitácora bloqueada o que no coincide con lo observado, y snapshot de Jira sin verificar o viejo.
    avisos = []
    if estado == "bloqueado":
        avisos.append("bloqueado" + (f": {front_bit.get('detalle')}" if front_bit.get("detalle") else ""))
    elif estado in ESTADOS and ESTADOS[estado] and ESTADOS[estado] != phase and t["type"] != "Pase a producción":
        avisos.append(f"bitácora dice «{estado}»")
    snap = snapshot_state(folder, t["updated"]) if folder.is_dir() else ""
    if snap:
        avisos.append("snapshot sin verificar" if snap == "pendiente" else "snapshot viejo")
    if avisos:
        detail = (detail + " · " if detail else "") + " · ".join(avisos)
    t.update({"next": nxt, "phase": phase, "phaseName": PHASES[phase], "detail": detail, "launch": {"cmds": cmds, "phrase": phrase},
              "estado": estado, "snapshot": snap,
              "prs": [{"number": p["number"], "repo": p["repo"], "url": p["url"], "decision": p["decision"]} for p in my_prs]})


def post_merge_phrase(key, pr):
    return (f"{key}: {pr} está aprobado. Sigue el paso «Aprobado» de AGENTS.md: recuérdame hacer yo el merge a qas (merge commit), "
            "comprueba el deploy de qas en verde, decide con pruebas.md §8 si va a QA (invio-qa-ticket) o lo valido yo, compara el peso "
            "estimado con el diff mergeado y propón la transición. Actualiza estado_trabajo y el punto de reanudación; nada se publica sin mi OK.")


def main():
    try:
        site, auth = jira_auth()
    except Exception:
        print(json.dumps({"error": "Falta configurar Jira (ver ~/.config/pr-tracker/config.json)", "tickets": []}))
        return
    try:
        extra = json.loads(CONFIG.read_text()).get("worktrees", {})
    except Exception:
        extra = {}
    try:
        with ThreadPoolExecutor(2) as ex:
            fj, fp = ex.submit(jira_tickets, site, auth), ex.submit(open_prs)
            tickets, prs = fj.result(), fp.result()
    except Exception as e:
        print(json.dumps({"error": "Jira/GitHub: " + str(e)[:150], "tickets": []}))
        return
    mine = {t["key"] for t in tickets}
    for t in tickets:
        classify(t, prs, extra, mine)
    tickets = [t for t in tickets if t["cat"] != "new" or t["phase"] > 1 or "--all" in sys.argv]
    tickets.sort(key=lambda t: (t["phase"], t["updated"]), reverse=False)
    if "--list" in sys.argv:
        for t in tickets:
            print("\t".join([t["key"], f"{t['phase']}·{t['phaseName']}", t["summary"], t["detail"],
                             ";;".join(c["cmd"] for c in t["launch"]["cmds"]), t["launch"]["phrase"]]))
        return
    print(json.dumps({"error": None, "tickets": tickets, "phases": PHASES}, ensure_ascii=False))


main()

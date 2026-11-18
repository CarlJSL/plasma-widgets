#!/usr/bin/env python3
"""ticket-tracker: mis tickets de Jira asignados y abiertos, ordenados por etapa del flujo.

Lee ~/.config/pr-tracker/config.json (jiraSite, jiraEnv, ticketStaleDays) y las credenciales de jiraEnv
(JIRA_EMAIL y JIRA_API_TOKEN). Imprime JSON.
"""
import base64, json, re, sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from urllib import request as urlrequest

HOME = Path.home()
CONFIG = HOME / ".config/pr-tracker/config.json"
JQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
FIELDS = ["summary", "status", "priority", "issuetype", "updated", "project"]

CACHE = HOME / ".cache/pr-tracker/boards.json"
BLOCKS = HOME / ".local/share/pr-tracker/blocks.json"
KEY = re.compile(r"[A-Z][A-Z0-9]+-\d+")

def load_blocks():
    try: return json.loads(BLOCKS.read_text())
    except Exception: return []

def save_blocks(items):
    BLOCKS.parent.mkdir(parents=True, exist_ok=True)
    BLOCKS.write_text(json.dumps(items, indent=2, ensure_ascii=False))

def block_cmd(args):
    """block add KEY BLOQUEADOR [nota] | block rm KEY | block ack KEY"""
    items = load_blocks()
    op, key = args[0], args[1].strip().upper()
    if op == "add":
        m = KEY.search(args[2].upper()) if len(args) > 2 else None
        if not m: print("Falta la clave del ticket que bloquea (por ejemplo IN-1700)"); sys.exit(1)
        blocker = m.group(0)
        if blocker == key: print("Un ticket no puede bloquearse a sí mismo"); sys.exit(1)
        items = [i for i in items if i["key"] != key]
        items.append({"key": key, "blocker": blocker, "note": " ".join(args[3:]).strip(),
                      "since": datetime.now(timezone.utc).isoformat(), "acked": False})
        print(f"{key} queda esperando a {blocker}")
    elif op == "rm":
        items = [i for i in items if i["key"] != key]
    elif op == "ack":
        for i in items:
            if i["key"] == key: i["acked"] = True
    save_blocks(items)

def api(site, auth, path):
    req = urlrequest.Request(f"https://{site}{path}", headers={"Authorization": auth, "Accept": "application/json"})
    with urlrequest.urlopen(req, timeout=25) as r:
        return json.loads(r.read())

def boards_of(site, auth, project):
    """Tableros del proyecto con sus columnas (cacheado un día: la configuración casi no cambia)."""
    try: cache = json.loads(CACHE.read_text())
    except Exception: cache = {}
    hit = cache.get(project)
    if hit and (datetime.now(timezone.utc).timestamp() - hit["at"]) < 86400:
        return hit["boards"]
    boards = []
    for b in api(site, auth, f"/rest/agile/1.0/board?projectKeyOrId={project}&maxResults=50")["values"]:
        try: c = api(site, auth, f"/rest/agile/1.0/board/{b['id']}/configuration")
        except Exception: continue
        boards.append({"id": b["id"], "name": b["name"],
                       "columns": [{"name": col["name"], "statuses": [x["id"] for x in col["statuses"]]}
                                   for col in c["columnConfig"]["columns"]]})
    cache[project] = {"at": datetime.now(timezone.utc).timestamp(), "boards": boards}
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(cache))
    return boards

def pick_board(boards, status_ids, forced):
    """El tablero configurado o, si no, el que cubre más de mis estados y, a igualdad, el de más columnas."""
    if forced:
        for b in boards:
            if b["id"] == forced: return b
    def score(b):
        have = {sid for c in b["columns"] for sid in c["statuses"]}
        return (len(status_ids & have), len(b["columns"]), -b["id"])
    return max(boards, key=score) if boards else None

def out(d): print(json.dumps(d, ensure_ascii=False))

def stage(status, cat):
    """Posición del estado en el flujo; los nombres cambian por proyecto, por eso se clasifica por palabras."""
    s = status.lower()
    if cat == "new": return 9
    if re.search(r"progress|desarrollo|desaroll|doing|curso", s): return 1
    if re.search(r"review|revisi", s): return 2
    if re.search(r"qa|test|prueba|valid", s): return 3
    if re.search(r"ready|deploy|aprob|listo|release", s): return 4
    return 5

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "block":
        block_cmd(sys.argv[2:]); return
    try:
        cfg = json.loads(CONFIG.read_text())
        site = cfg["jiraSite"]
        env = {}
        for line in Path(cfg.get("jiraEnv", "~/.config/pr-tracker/jira.env")).expanduser().read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1); env[k.strip()] = v.strip().strip("'\"")
        auth = "Basic " + base64.b64encode(f"{env['JIRA_EMAIL']}:{env['JIRA_API_TOKEN']}".encode()).decode()
    except Exception:
        out({"error": "Falta configurar Jira (jiraSite y jiraEnv en ~/.config/pr-tracker/config.json)", "tickets": []}); return
    stale_days = int(cfg.get("ticketStaleDays", 3))
    tickets, token = [], None
    try:
        while True:
            body = {"jql": JQL, "maxResults": 100, "fields": FIELDS}
            if token: body["nextPageToken"] = token
            req = urlrequest.Request(f"https://{site}/rest/api/3/search/jql", data=json.dumps(body).encode(),
                headers={"Authorization": auth, "Content-Type": "application/json", "Accept": "application/json"})
            with urlrequest.urlopen(req, timeout=25) as r:
                d = json.loads(r.read())
            for i in d["issues"]:
                f = i["fields"]
                cat = f["status"]["statusCategory"]["key"]
                idle = (datetime.now(timezone.utc) - datetime.fromisoformat(f["updated"].replace("Z", "+00:00").replace("+0000", "+00:00"))).days
                st = stage(f["status"]["name"], cat)
                tickets.append({"statusId": f["status"]["id"], "key": i["key"], "summary": f["summary"], "status": f["status"]["name"], "cat": cat,
                                "stage": st, "type": f["issuetype"]["name"], "priority": (f["priority"] or {}).get("name", ""),
                                "project": f["project"]["key"], "updated": f["updated"], "idleDays": idle,
                                "stale": st in (1, 2, 3, 5) and idle >= stale_days, "url": f"https://{site}/browse/{i['key']}"})
            token = d.get("nextPageToken")
            if d.get("isLast", True) or not token: break
    except Exception as e:
        out({"error": "Jira: " + str(e)[:150], "tickets": []}); return
    # Orden según el tablero de Jira: tablero → columna → más reciente primero.
    chosen = {}
    forced = cfg.get("boards", {})
    for proj in sorted({t["project"] for t in tickets}):
        try:
            boards = boards_of(site, auth, proj)
            ids = {t["statusId"] for t in tickets if t["project"] == proj}
            chosen[proj] = pick_board(boards, ids, forced.get(proj))
        except Exception:
            chosen[proj] = None
    for t in tickets:
        b = chosen.get(t["project"])
        col, idx = t["status"], 999
        if b:
            for n, c in enumerate(b["columns"]):
                if t["statusId"] in c["statuses"]:
                    col, idx = c["name"], n; break
        t["board"] = b["name"] if b else t["project"]
        t["column"], t["colIndex"] = col, idx
    # los tableros con más tickets activos primero
    weight = {}
    for t in tickets:
        if t["cat"] != "new": weight[t["board"]] = weight.get(t["board"], 0) + 1
    tickets.sort(key=lambda t: t["updated"], reverse=True)
    tickets.sort(key=lambda t: (-weight.get(t["board"], 0), t["board"], t["colIndex"]))
    for t in tickets: t["sec"] = t["board"] + " › " + t["column"]
    # Bloqueos propios: "no puedo avanzar KEY hasta terminar BLOQUEADOR"
    blocks = load_blocks()
    by_key = {t["key"]: t for t in tickets}
    def issue(k):
        try:
            f = api(site, auth, f"/rest/api/3/issue/{k}?fields=summary,status")["fields"]
            return {"summary": f["summary"], "status": f["status"]["name"], "done": f["status"]["statusCategory"]["key"] == "done"}
        except Exception:
            return {"summary": "(no se pudo leer)", "status": "?", "done": False}
    need = {k for b in blocks for k in (b["blocker"], b["key"]) if k not in by_key}
    with ThreadPoolExecutor(max_workers=6) as ex:
        info = dict(zip(need, ex.map(issue, need)))
    for k, t in by_key.items(): info[k] = {"summary": t["summary"], "status": t["status"], "done": False}
    view = []
    for b in blocks:
        blk, me = info.get(b["blocker"]), info.get(b["key"])
        since = datetime.fromisoformat(b["since"])
        view.append({"key": b["key"], "summary": (me or {}).get("summary", ""), "status": (me or {}).get("status", ""),
                     "blocker": b["blocker"], "blockerSummary": (blk or {}).get("summary", ""),
                     "blockerStatus": (blk or {}).get("status", ""), "blockerDone": bool((blk or {}).get("done")),
                     "blockerUrl": f"https://{site}/browse/{b['blocker']}", "url": f"https://{site}/browse/{b['key']}",
                     "note": b.get("note", ""), "daysBlocked": (datetime.now(timezone.utc) - since).days, "acked": b.get("acked", False)})
    blocked_keys = {b["key"]: b["blocker"] for b in blocks}
    for t in tickets: t["blockedBy"] = blocked_keys.get(t["key"])
    out({"error": None, "tickets": tickets, "blocks": view, "staleDays": stale_days})

main()

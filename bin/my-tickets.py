#!/usr/bin/env python3
"""ticket-tracker: mis tickets de Jira asignados y abiertos, ordenados por etapa del flujo.

Lee ~/.config/pr-tracker/config.json (jiraSite, jiraEnv, ticketStaleDays) y las credenciales de jiraEnv
(JIRA_EMAIL y JIRA_API_TOKEN). Imprime JSON.
"""
import base64, json, re
from datetime import datetime, timezone
from pathlib import Path
from urllib import request as urlrequest

HOME = Path.home()
CONFIG = HOME / ".config/pr-tracker/config.json"
JQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
FIELDS = ["summary", "status", "priority", "issuetype", "updated", "project"]

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
                tickets.append({"key": i["key"], "summary": f["summary"], "status": f["status"]["name"], "cat": cat,
                                "stage": st, "type": f["issuetype"]["name"], "priority": (f["priority"] or {}).get("name", ""),
                                "project": f["project"]["key"], "updated": f["updated"], "idleDays": idle,
                                "stale": st in (1, 2, 3, 5) and idle >= stale_days, "url": f"https://{site}/browse/{i['key']}"})
            token = d.get("nextPageToken")
            if d.get("isLast", True) or not token: break
    except Exception as e:
        out({"error": "Jira: " + str(e)[:150], "tickets": []}); return
    # por etapa del flujo; dentro de cada estado, lo más reciente primero
    tickets.sort(key=lambda t: t["updated"], reverse=True)
    tickets.sort(key=lambda t: (t["stage"], t["status"]))
    out({"error": None, "tickets": tickets, "staleDays": stale_days})

main()

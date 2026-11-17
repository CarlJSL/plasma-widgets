#!/usr/bin/env python3
"""pr-tracker: mis PRs abiertos, PRs que me piden revisar y PRs ajenos en seguimiento.

Uso:
  my-prs [--widget]                 JSON con todo (--widget: guarda el estado del recordatorio diario)
  my-prs watch add URL [nota]       seguir un PR ajeno
  my-prs watch rm URL               dejar de seguirlo
  my-prs watch ack URL              marcar como avisado (lo usa el widget)
  my-prs rereview CUENTA URL        pedir re-review a quienes ya revisaron el PR
"""
import json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib import request as urlrequest

HOME = Path.home()
DATA = HOME / ".local/share/pr-tracker"
WATCH = DATA / "watch.json"
STATE = DATA / "state.json"
CONFIG = HOME / ".config/pr-tracker/config.json"
JIRA_ENV = HOME / ".config/pr-tracker/jira.env"  # configurable con "jiraEnv" en config.json

PR_FIELDS = """
  number title url isDraft createdAt updatedAt mergeable reviewDecision
  baseRefName headRefName headRefOid author { login }
  latestReviews(first: 10) { nodes { state author { login } commit { oid } } }
  repository { nameWithOwner name }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
"""
Q_MINE = "query { search(query: \"is:pr is:open author:@me archived:false sort:updated-desc\", type: ISSUE, first: 50) { nodes { ... on PullRequest { %s } } } }" % PR_FIELDS
Q_REVIEW = "query { search(query: \"is:pr is:open review-requested:@me draft:false archived:false sort:updated-desc\", type: ISSUE, first: 50) { nodes { ... on PullRequest { %s } } } }" % PR_FIELDS
Q_MERGED = "query($q:String!) { search(query: $q, type: ISSUE, first: 50) { nodes { ... on PullRequest { %s mergedAt } } } }" % PR_FIELDS
Q_ONE = "query($o:String!,$r:String!,$n:Int!) { repository(owner:$o,name:$r) { pullRequest(number:$n) { %s state mergedAt closedAt } } }" % PR_FIELDS


def sh(cmd, env=None, timeout=45):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=True, env=env).stdout

def load(path, default):
    try: return json.loads(path.read_text())
    except Exception: return default

def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))

def now(): return datetime.now(timezone.utc)

def days_since(iso):
    return max(0, (now() - datetime.fromisoformat(iso.replace("Z", "+00:00"))).days)

def accounts():
    out = sh(["gh", "auth", "status", "--json", "hosts"], timeout=20)
    return [a["login"] for a in json.loads(out)["hosts"].get("github.com", []) if a["state"] == "success"]

def env_for(login):
    token = sh(["gh", "auth", "token", "-u", login], timeout=20).strip()
    return {**os.environ, "GH_TOKEN": token}

def gql(env, query, **vars):
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for k, v in vars.items():
        cmd += ["-F" if isinstance(v, int) else "-f", f"{k}={v}"]
    return json.loads(sh(cmd, env=env))["data"]


# ---------- estado de un PR ----------
def ci_state(pr):
    c = pr["commits"]["nodes"]
    return ((c[0]["commit"]["statusCheckRollup"] or {}).get("state")) if c else None

def status(pr):
    ci = ci_state(pr)
    if pr["isDraft"]:
        return "draft", "Draft"
    re_review = False
    if pr["reviewDecision"] == "CHANGES_REQUESTED":
        # Observado solo si la observación es sobre el último commit; si subí cambios después, espera re-review.
        vigente = any(r["state"] == "CHANGES_REQUESTED" and (r["commit"] or {}).get("oid") == pr["headRefOid"]
                      for r in pr["latestReviews"]["nodes"])
        if vigente:
            return "observado", "Observado"
        re_review = True
    if pr["mergeable"] == "CONFLICTING":
        return "conflicto", "Conflictos"
    if ci in ("FAILURE", "ERROR"):
        return "ci", "CI fallando"
    if ci in ("PENDING", "EXPECTED"):
        return "probando", "CI en curso"
    if re_review:
        return "review", "Esperando re-review"
    if pr["reviewDecision"] == "APPROVED":
        return "aprobado", "Aprobado"
    return "review", "Esperando review"

def base(pr, login):
    return {"account": login, "repo": pr["repository"]["name"], "owner": pr["repository"]["nameWithOwner"],
            "number": pr["number"], "title": pr["title"], "url": pr["url"],
            "author": (pr["author"] or {}).get("login", ""), "branch": pr["headRefName"], "base": pr["baseRefName"],
            "createdAt": pr["createdAt"], "updatedAt": pr["updatedAt"], "ageDays": days_since(pr["createdAt"]),
            "idleDays": days_since(pr["updatedAt"])}

TICKET = re.compile(r"\b([A-Z][A-Z0-9]{1,9}-\d+)\b")
def ticket_of(pr):
    m = TICKET.search(pr["title"]) or TICKET.search(pr["branch"].upper())
    return m.group(1) if m else None


# ---------- Jira (opcional) ----------
def jira_conf():
    cfg = load(CONFIG, {})
    site = cfg.get("jiraSite")
    creds = {}
    try:
        env_path = Path(cfg.get("jiraEnv", str(JIRA_ENV))).expanduser()
        for line in env_path.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1); creds[k.strip()] = v.strip().strip("'\"")
    except Exception:
        return None
    if site and creds.get("JIRA_EMAIL") and creds.get("JIRA_API_TOKEN"):
        return site, creds["JIRA_EMAIL"], creds["JIRA_API_TOKEN"]
    return None

def jira_status(conf, key):
    import base64
    site, email, token = conf
    req = urlrequest.Request(f"https://{site}/rest/api/3/issue/{key}?fields=status",
        headers={"Authorization": "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode(), "Accept": "application/json"})
    try:
        with urlrequest.urlopen(req, timeout=15) as r:
            return json.loads(r.read())["fields"]["status"]["name"]
    except Exception:
        return None


# ---------- seguimiento de PRs ajenos ----------
def parse_url(url):
    m = re.match(r"https://github\.com/([^/]+)/([^/]+)/pull/(\d+)", url.strip())
    if not m: raise ValueError("URL de PR no válida (https://github.com/<owner>/<repo>/pull/<n>)")
    return m.group(1), m.group(2), int(m.group(3))

def watch_cmd(args):
    items = load(WATCH, [])
    op, url = args[0], args[1]
    url = url.strip().split("#")[0].split("?")[0].rstrip("/")
    url = re.sub(r"(/pull/\d+).*", r"\1", url)
    if op == "add":
        parse_url(url)
        items = [i for i in items if i["url"] != url]
        items.append({"url": url, "note": " ".join(args[2:]).strip(), "addedAt": now().isoformat(), "acked": False})
        print("Siguiendo " + url)
    elif op == "rm":
        items = [i for i in items if i["url"] != url]
    elif op == "ack":
        for i in items:
            if i["url"] == url: i["acked"] = True
    save(WATCH, items)

def watch_status(pr):
    """Estado de un PR ajeno: sin la lógica de "observado/re-review", que es de quien lo abrió."""
    ci = ci_state(pr)
    if pr["isDraft"]: return "draft", "Draft"
    if pr["mergeable"] == "CONFLICTING": return "conflicto", "Conflictos"
    if ci in ("FAILURE", "ERROR"): return "ci", "CI fallando"
    if pr["reviewDecision"] == "CHANGES_REQUESTED": return "observado", "Con cambios solicitados"
    if ci in ("PENDING", "EXPECTED"): return "probando", "CI en curso"
    if pr["reviewDecision"] == "APPROVED": return "aprobado", "Aprobado, falta el merge"
    return "review", "En review"

def fetch_watch(item, logins, envs):
    o, r, n = parse_url(item["url"])
    for login in logins:
        try:
            pr = gql(envs[login], Q_ONE, o=o, r=r, n=n)["repository"]["pullRequest"]
        except Exception:
            continue
        if not pr: continue
        if pr["state"] == "MERGED": st, label = "mergeado", "Mergeado"
        elif pr["state"] == "CLOSED": st, label = "cerrado", "Cerrado sin merge"
        else: st, label = watch_status(pr)
        d = base(pr, login)
        d.update({"status": st, "label": label, "note": item.get("note", ""), "acked": item.get("acked", False),
                  "state": pr["state"]})
        return d
    return {"url": item["url"], "owner": f"{o}/{r}", "repo": r, "number": n, "title": "(sin acceso o no existe)",
            "status": "error", "label": "No se pudo leer", "note": item.get("note", ""), "acked": True, "state": "UNKNOWN",
            "author": "", "account": "", "branch": "", "base": "", "ageDays": 0, "idleDays": 0}


# ---------- re-review ----------
def rereview(login, url):
    o, r, n = parse_url(url)
    env = env_for(login)
    pr = gql(env, Q_ONE, o=o, r=r, n=n)["repository"]["pullRequest"]
    who = sorted({x["author"]["login"] for x in pr["latestReviews"]["nodes"] if x["author"] and x["author"]["login"] != login})
    if not who:
        print("No hay revisores previos a quienes pedir re-review"); return
    cmd = ["gh", "pr", "edit", url]
    for w in who: cmd += ["--add-reviewer", w]
    sh(cmd, env=env)
    print("Re-review pedida a: " + ", ".join(who))


# ---------- principal ----------
def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "watch":
        watch_cmd(argv[1:]); return
    if argv and argv[0] == "rereview":
        try: rereview(argv[1], argv[2])
        except subprocess.CalledProcessError as e:
            print("Error: " + (e.stderr or str(e)).strip()[:200]); sys.exit(1)
        return

    cfg = load(CONFIG, {})
    stale_days = int(cfg.get("staleDays", 2))
    merged_days = int(cfg.get("mergedDays", 5))
    try:
        logins = accounts()
    except Exception as e:
        print(json.dumps({"error": str(e)[:200], "prs": [], "review": [], "watching": [], "accounts": [], "failed": []})); return
    envs, errors, failed = {}, [], []
    for l in logins:
        try: envs[l] = env_for(l)
        except Exception as e: errors.append(f"{l}: {str(e)[:120]}"); failed.append(l)
    ok = [l for l in logins if l in envs]

    def per_account(login):
        d = gql(envs[login], Q_MINE)
        r = gql(envs[login], Q_REVIEW)
        since = (now() - timedelta(days=merged_days)).strftime("%Y-%m-%d")
        m = gql(envs[login], Q_MERGED, q=f"is:pr is:merged author:@me merged:>={since} sort:updated-desc")
        return login, d["search"]["nodes"], r["search"]["nodes"], m["search"]["nodes"]

    prs, review, merged = [], [], []
    with ThreadPoolExecutor(max_workers=6) as ex:
        futs = {l: ex.submit(per_account, l) for l in ok}
        watch_items = load(WATCH, [])
        wfut = [ex.submit(fetch_watch, i, ok, envs) for i in watch_items]
        for l, f in futs.items():
            try:
                _, mine, rev, mer = f.result()
            except Exception as e:
                errors.append(f"{l}: {str(e)[:120]}"); failed.append(l); continue
            for n in mine:
                if not n: continue
                key, label = status(n)
                d = base(n, l); d.update({"status": key, "label": label, "ci": ci_state(n)}); prs.append(d)
            for n in mer:
                if not n: continue
                d = base(n, l)
                d.update({"status": "mergeado", "label": "Mergeado", "mergedAt": n["mergedAt"],
                          "mergedDaysAgo": days_since(n["mergedAt"])})
                if (now() - datetime.fromisoformat(n["mergedAt"].replace("Z", "+00:00"))).days < merged_days: merged.append(d)
            for n in rev:
                if not n: continue
                d = base(n, l); d.update({"status": "review", "label": "Pide tu review"}); review.append(d)
        watching = [f.result() for f in wfut]

    # Jira (opcional): estado del ticket de cada PR mío
    conf = jira_conf()
    if conf:
        keys = {}
        for p in prs + merged:
            k = TICKET.search(p["title"]) or TICKET.search(p["branch"].upper())
            p["ticket"] = k.group(1) if k else None
            if p["ticket"]: keys[p["ticket"]] = None
        with ThreadPoolExecutor(max_workers=6) as ex:
            for k, v in zip(keys, ex.map(lambda k: jira_status(conf, k), keys)): keys[k] = v
        for p in prs + merged: p["ticketStatus"] = keys.get(p["ticket"]) if p.get("ticket") else None
    for p in prs: p["stale"] = p["status"] == "review" and p["idleDays"] >= stale_days
    for p in review: p["stale"] = p["idleDays"] >= stale_days

    # Orden: más reciente primero (por creación), agrupado por repo con el repo del PR más nuevo arriba.
    def order(lst):
        lst.sort(key=lambda p: p["createdAt"], reverse=True)
        top = {}
        for p in lst: top.setdefault(p["owner"], p["createdAt"])
        lst.sort(key=lambda p: (top[p["owner"]], p["createdAt"]), reverse=True)
    order(prs); order(review)
    merged.sort(key=lambda p: p["mergedAt"], reverse=True)

    # Recordatorio diario de estancados (solo el widget consume el aviso)
    remind = []
    if "--widget" in argv:
        st = load(STATE, {})
        today = datetime.now().strftime("%Y-%m-%d")
        stale = [p for p in prs if p["stale"]] + [p for p in review if p["stale"]]
        if stale and st.get("lastReminder") != today and datetime.now().hour >= 9:
            remind = [{"repo": p["repo"], "number": p["number"], "idleDays": p["idleDays"]} for p in stale]
            st["lastReminder"] = today; save(STATE, st)

    print(json.dumps({"error": "; ".join(errors) or None, "prs": prs, "review": review, "merged": merged, "watching": watching,
                      "remind": remind, "accounts": logins, "failed": failed, "jira": bool(conf), "staleDays": stale_days, "mergedDays": merged_days}))

main()

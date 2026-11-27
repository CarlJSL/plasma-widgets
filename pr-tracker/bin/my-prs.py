#!/usr/bin/env python3
"""pr-tracker: mis PRs abiertos, PRs que me piden revisar y PRs ajenos en seguimiento.

Uso:
  my-prs [--widget]                 JSON con todo (--widget: guarda el estado del recordatorio diario)
  my-prs watch add URL [nota]       seguir un PR ajeno
  my-prs watch rm URL               dejar de seguirlo
  my-prs watch ack URL              marcar como avisado (lo usa el widget)
  my-prs rereview CUENTA URL        pedir re-review a quienes ya revisaron el PR
  my-prs codereview CUENTA URL otros|mio   code review con IA (otros: agente de `harnessDir` si existe; mio: autorreview en tu worktree)
  my-prs batch CUENTA URL [CUENTA URL ...]   primera pasada de code review de varios PRs en segundo plano (borradores)
  my-prs batch-stop                          cancelar el lote en curso
  my-prs review CUENTA URL [code|term]  preparar un worktree del PR y abrirlo para leer el código
                                    (list: solo imprime el orden; git: abre solo la carpeta para usar Control de código fuente; code: VS Code con los archivos sin ver, en orden de lectura;
                                     term: diff en la terminal con delta, en el mismo orden)
"""
import json, os, re, shlex, signal, subprocess, sys, threading
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
  latestReviews(first: 10) { nodes { state submittedAt author { login } commit { oid } } }
  reviews(last: 40) { nodes { state submittedAt author { login } commit { oid } } }
  reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
  repository { nameWithOwner name }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
"""
Q_MINE = "query { search(query: \"is:pr is:open author:@me archived:false sort:updated-desc\", type: ISSUE, first: 50) { nodes { ... on PullRequest { %s } } } }" % PR_FIELDS
Q_REVIEW = "query { search(query: \"is:pr is:open review-requested:@me draft:false archived:false sort:updated-desc\", type: ISSUE, first: 50) { nodes { ... on PullRequest { %s files(first: 100) { totalCount nodes { path viewerViewedState } } } } } }" % PR_FIELDS
Q_FILES = "query($o:String!,$r:String!,$n:Int!) { repository(owner:$o,name:$r) { pullRequest(number:$n) { title baseRefName headRefName files(first: 100) { nodes { path viewerViewedState } } } } }"
Q_LASTREV = "query($o:String!,$r:String!,$n:Int!) { repository(owner:$o,name:$r) { pullRequest(number:$n) { headRefOid viewerLatestReview { state submittedAt commit { oid } } } } }"
Q_MERGED = "query($q:String!) { search(query: $q, type: ISSUE, first: 50) { nodes { ... on PullRequest { %s mergedAt } } } }" % PR_FIELDS
Q_REVIEWED = "query($q:String!) { search(query: $q, type: ISSUE, first: 50) { nodes { ... on PullRequest { %s state mergedAt viewerLatestReview { state submittedAt commit { oid } } files(first: 100) { totalCount nodes { path viewerViewedState } } } } } }" % PR_FIELDS
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

def latest_reviews(pr):
    """Último review enviado de cada persona, con su fecha y si fue sobre el último commit. Se lee del historial (`reviews`) y no de
    `latestReviews`: GitHub saca de ahí a quien se le vuelve a pedir review, y su review anterior se perdería."""
    last = {}
    for x in (pr.get("reviews") or pr["latestReviews"])["nodes"]:
        if not x.get("author") or x["state"] == "PENDING" or not x.get("submittedAt"): continue
        k = x["author"]["login"]
        if k not in last or x["submittedAt"] >= last[k]["submittedAt"]: last[k] = x
    return [{"login": k, "state": x["state"], "at": x["submittedAt"],
             "current": (x["commit"] or {}).get("oid") == pr.get("headRefOid")} for k, x in last.items()]

def base(pr, login):
    return {"account": login, "repo": pr["repository"]["name"], "owner": pr["repository"]["nameWithOwner"],
            "number": pr["number"], "title": pr["title"], "url": pr["url"],
            "author": (pr["author"] or {}).get("login", ""), "branch": pr["headRefName"], "base": pr["baseRefName"],
            "sha": pr.get("headRefOid", ""), "createdAt": pr["createdAt"], "updatedAt": pr["updatedAt"], "ageDays": days_since(pr["createdAt"]),
            "idleDays": days_since(pr["updatedAt"]),
            "reviews": latest_reviews(pr),
            "requested": [((x.get("requestedReviewer") or {}).get("login") or (x.get("requestedReviewer") or {}).get("name") or "")
                          for x in (pr.get("reviewRequests") or {}).get("nodes", [])]}

TICKET = re.compile(r"\b([A-Z][A-Z0-9]{1,9}-\d+)\b")
def ticket_of(pr):
    m = TICKET.search(pr["title"]) or TICKET.search(pr["branch"].upper())
    return m.group(1) if m else None


# ---------- cambios con varios PRs (front + back) ----------
def role_of(repo):
    r = repo.lower()
    if r.startswith(("st-", "front-", "app-")) or r.endswith(("-front", "-app")): return "front"
    if r.startswith(("api-", "back-", "fn-")) or r.endswith(("-api", "-back")): return "back"
    return repo

def family(repo):
    r = re.sub(r"^(st|api|fn|front|back|app)-", "", repo.lower())
    return re.sub(r"-(front|back|api|app)$", "", r)

def norm_title(t):
    t = re.sub(r"^\s*\w+(\([^)]*\))?!?:\s*", "", t.lower())
    t = re.sub(r"\((app|api|front|back|frontend|backend|st|fe|be)\)", "", t)
    return re.sub(r"\s+", " ", t).strip(" -·")

def related(a, b):
    """Dos PRs de repos distintos pertenecen al mismo cambio: mismo ticket, o par st-/api- con el mismo título."""
    if a["owner"] == b["owner"]: return False
    if a.get("ticket") and a.get("ticket") == b.get("ticket"): return True
    nt = norm_title(a["title"])
    return len(nt) >= 12 and family(a["repo"]) == family(b["repo"]) and nt == norm_title(b["title"])

BAD = ("observado", "conflicto", "ci")

def build_groups(prs, merged):
    items = prs + merged
    parent = list(range(len(items)))
    def find(i):
        while parent[i] != i: parent[i] = parent[parent[i]]; i = parent[i]
        return i
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            if related(items[i], items[j]): parent[find(i)] = find(j)
    comps = {}
    for i, it in enumerate(items): comps.setdefault(find(i), []).append(it)
    groups = []
    for members in comps.values():
        open_ = [m for m in members if m["status"] != "mergeado"]
        if len(members) < 2 or not open_: continue
        roles = [role_of(m["repo"]) for m in members]
        def name(m):
            r = role_of(m["repo"])
            return r if roles.count(r) == 1 else f"{m['repo']} #{m['number']}"
        done = [m for m in members if m["status"] == "mergeado"]
        warns, code, tone = [], None, "wait"
        bad = [m for m in open_ if m["status"] in BAD]
        appr = [m for m in open_ if m["status"] == "aprobado"]
        if done:
            code, tone = "desync", "bad"
            warns.append(", ".join(name(m) for m in done) + " ya se mergeó; falta: "
                         + ", ".join(f"{name(m)} ({m['label']})" for m in open_))
        elif len(appr) == len(open_):
            code, tone = "ready", "ok"
            warns.append("Todos aprobados: se pueden mergear juntos")
        elif appr and bad:
            code, tone = "mixed", "bad"
            warns.append(", ".join(name(m) for m in appr) + " aprobado, pero "
                         + ", ".join(f"{name(m)}: {m['label']}" for m in bad))
        elif appr:
            warns.append(", ".join(name(m) for m in appr) + " aprobado; falta "
                         + ", ".join(f"{name(m)} ({m['label']})" for m in open_ if m["status"] != "aprobado"))
        elif bad:
            tone = "bad"
        title = norm_title(members[0]["title"])
        tickets = sorted({m["ticket"] for m in members if m.get("ticket")})
        members.sort(key=lambda m: (m["status"] == "mergeado", role_of(m["repo"]) != "front", m["repo"]))
        gid = "|".join(sorted(m["url"] for m in members))
        groups.append({"id": gid, "title": (title[:1].upper() + title[1:]) if title else " + ".join(tickets),
                       "tickets": tickets, "code": code, "tone": tone, "warnings": warns,
                       "createdAt": max(m["createdAt"] for m in members),
                       "members": [{"name": name(m), "status": m["status"], "label": m["label"], "url": m["url"],
                                    "number": m["number"], "repo": m["repo"]} for m in members], "_m": members})
    groups.sort(key=lambda g: g["createdAt"], reverse=True)
    return groups

def mine_view(prs, groups):
    """Lista plana para el widget: cada cambio agrupado (sec = g:<id>) seguido de los PRs sueltos por repo."""
    view, used = [], set()
    for g in groups:
        for m in g.pop("_m"):
            used.add(m["url"]); view.append({**m, "sec": "g:" + g["id"], "role": role_of(m["repo"])})
    for p in prs:
        if p["url"] not in used: view.append({**p, "sec": p["repo"], "role": ""})
    return view

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


# ---------- revisar el código ----------
SKIP_FILE = re.compile(r"(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|[^/]+\.lock|[^/]+\.snap|[^/]+\.min\.js)$|(^|/)(dist|generated)/")

def read_rank(path):
    """Orden de lectura: migraciones y contratos, entradas, lógica, tests, estilos, resto."""
    p = path.lower()
    if SKIP_FILE.search(p): return 9
    if re.search(r"\.(spec|test)\.|(^|/)(test|tests|__tests__|e2e)/", p): return 4
    if "migration" in p: return 0
    if re.search(r"(dto|entity|entities|model|interface|\.types?)\b|\.d\.ts$", p): return 1
    if re.search(r"controller|\.module\.|routes?|resolver|handler", p): return 2
    if re.search(r"\.(s?css|less)$", p): return 5
    if re.search(r"\.(md|json|ya?ml|toml|env\w*)$|dockerfile", p): return 6
    return 3

def reading_order(paths):
    return sorted(paths, key=lambda f: (read_rank(f), f))

def find_clone(owner, repo, cfg):
    """Busca un clon local del repo (por su remote) en reposDir; si no hay, hace un clon parcial en la caché."""
    root = Path(os.path.expanduser(cfg.get("reposDir", "~/Proyectos")))
    want = f"{owner}/{repo}".lower()
    cands = [d for d in root.glob("*") if d.is_dir()] + [d for d in root.glob("*/*") if d.is_dir()]
    for d in cands:
        if not (d / ".git").is_dir(): continue
        try: url = sh(["git", "-C", str(d), "remote", "get-url", "origin"], timeout=10).strip().lower()
        except Exception: continue
        if re.search(r"[:/]" + re.escape(want) + r"(\.git)?$", url): return d
    dest = HOME / ".cache/pr-tracker/repos" / owner / repo
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        sh(["git", "clone", "--filter=blob:none", f"https://github.com/{owner}/{repo}.git", str(dest)], timeout=300)
    return dest

def prepare_wt(login, url, cfg):
    """Deja el PR listo en un worktree: el tuyo si la rama ya está abierta, o uno nuevo en reviewDir."""
    o, r, n = parse_url(url)
    env = env_for(login)
    pr = gql(env, Q_FILES, o=o, r=r, n=n)["repository"]["pullRequest"]
    base = pr["baseRefName"]
    clone = find_clone(o, r, cfg)
    g = ["git", "-C", str(clone)]
    sh(g + ["fetch", "-q", "origin", f"+refs/heads/{base}:refs/remotes/origin/{base}"], timeout=120)
    # Si la rama del PR ya está abierta en un worktree tuyo (tus propios PRs), se usa ese.
    wt = None
    cur = None
    for line in sh(g + ["worktree", "list", "--porcelain"]).splitlines():
        if line.startswith("worktree "): cur = line[9:]
        elif line == f"branch refs/heads/{pr['headRefName']}": wt = Path(cur); break
    if wt is None:
        sh(g + ["fetch", "-q", "origin", f"pull/{n}/head"], timeout=120)
        head = sh(g + ["rev-parse", "FETCH_HEAD"]).strip()
        wt = Path(os.path.expanduser(cfg.get("reviewDir", "~/Proyectos/worktrees"))) / f"{r}-pr{n}"
        if wt.exists(): sh(["git", "-C", str(wt), "checkout", "-q", "--detach", head])
        else: sh(g + ["worktree", "add", "-q", "--detach", str(wt), head], timeout=120)
    return o, r, n, pr, base, wt

def my_last_review(login, o, r, n):
    """Mi último review del PR y si el PR recibió commits después: (estado, sha revisado, sha actual) o None."""
    pr = gql(env_for(login), Q_LASTREV, o=o, r=r, n=n)["repository"]["pullRequest"]
    v = pr.get("viewerLatestReview")
    oid = ((v or {}).get("commit") or {}).get("oid")
    if not v or not oid or oid == pr["headRefOid"]: return None
    return v["state"], oid, pr["headRefOid"]

def have_commit(g, oid):
    """El commit existe en el clon (si se reescribió la historia puede no estar: se intenta traer por sha)."""
    ok = lambda: subprocess.run(g + ["cat-file", "-e", oid + "^{commit}"], capture_output=True).returncode == 0
    if ok(): return True
    subprocess.run(g + ["fetch", "-q", "origin", oid], capture_output=True, timeout=120)
    return ok()

STATE_ES = {"APPROVED": "aprobé", "CHANGES_REQUESTED": "pedí cambios", "COMMENTED": "comenté", "DISMISSED": "descartado"}

def launch_terminal(cfg, cwd, command):
    """Abre una terminal en cwd que ejecuta `command` (y se queda abierta mientras dure)."""
    term = cfg.get("terminal", "kitty")
    sh_cmd = f"cd {shlex.quote(str(cwd))} && exec {command}"
    argv = [term, "sh", "-c", sh_cmd] if term == "kitty" else [term, "-e", "sh", "-c", sh_cmd]
    if os.environ.get("PR_TRACKER_DRY"): print("DRY:", sh_cmd); return
    subprocess.Popen(argv, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def codereview_cmd(args):
    """codereview CUENTA URL otros|mio
    otros: si hay `harnessDir`, sesión de Claude ahí con el agente `reviewAgent` (prepara un borrador; tú apruebas cada
           publicación); si no, prepara el PR en un worktree y corre el review integrado de Claude Code.
    mio:   autorreview de tu propio PR en el worktree de su rama (`selfReviewPrompt`); no publica nada."""
    login, url, who = args[0], args[1], args[2] if len(args) > 2 else "otros"
    cfg = load(CONFIG, {})
    self_prompt = cfg.get("selfReviewPrompt", "/code-review")
    harness = cfg.get("harnessDir")
    if who != "mio" and harness:
        o, r, n = parse_url(url)
        harness = Path(os.path.expanduser(harness))
        if not harness.is_dir(): print(f"No existe harnessDir: {harness}"); sys.exit(1)
        agent = cfg.get("reviewAgent", "review")
        msg = f"Revisa el PR {o}/{r}#{n} ({url}). Arma el borrador con la estructura de plantillas/review.md"
        try: lr = my_last_review(login, o, r, n)
        except Exception: lr = None
        if lr:
            msg = (f"Re-revisión del PR {o}/{r}#{n} ({url}). Mi review anterior ({STATE_ES.get(lr[0], lr[0])}) fue sobre el commit {lr[1][:8]} y el PR "
                   f"ya está en {lr[2][:8]}. Revisa solo lo que cambió desde mi review (git diff {lr[1][:8]}..{lr[2][:8]}, sin lo que entró de la base por un merge) "
                   "con tu método de re-revisión: cada punto de mi review anterior queda resuelto, sigue o resuelto a medias, con la línea. "
                   "Si dejas borrador, usa la estructura de plantillas/review.md. No publiques nada; muéstrame el resultado y espera mi OK")
        draft = reviews_view().get(url, {})
        if not lr and draft.get("status") == "done" and Path(draft.get("draft", "")).exists():
            msg += (f". Ya hay un borrador de primera pasada en {draft['draft']} (hecho sin build ni tests): léelo, verifícalo "
                    "contra el código, complétalo con lo que quedó en «No verifiqué» y muéstramelo completo; espera mi OK para publicar.")
        launch_terminal(cfg, harness, f"claude --agent {agent} " + shlex.quote(msg))
    else:
        o, r, n, pr, base, wt = prepare_wt(login, url, cfg)
        launch_terminal(cfg, wt, "claude " + shlex.quote(self_prompt))
    print(f"Code review de #{n} abierto en la terminal")

RESOLVE_PROMPT = (
    "Estás en el worktree del PR {o}/{r}#{n} (rama {head}). {situacion}\n\n"
    "## Resolver\n"
    "1. Por cada archivo en conflicto, entiende qué cambió cada lado y por qué: git log origin/{base} -5 -- <archivo>, git diff --merge <archivo>, "
    "y la intención de este PR (git log origin/{base}..HEAD, descripción con gh pr view). No elijas un lado por defecto: conserva la intención de los dos.\n"
    "2. Lockfiles y archivos generados no se mezclan a mano: toma el lado de origin/{base} y regenera con el gestor de paquetes. "
    "Migraciones: si dos tocan lo mismo, dímelo antes de decidir.\n"
    "3. Si no es obvio qué intención gana, pregúntame; no adivines.\n"
    "4. Sin marcadores <<<<<<<, ======= ni >>>>>>>; que compile.\n\n"
    "## Antes de pedirme el OK de commit y de push (hazlo tú, en este orden, y muéstrame cada resultado)\n"
    "a. Tests de lo que tocaste y el build; di cuáles corriste y cuáles no.\n"
    "b. Volumen de tests: git diff --numstat origin/{base}...HEAD; cifra de líneas de test (*.spec.ts, test/, e2e) contra las de código. Si el test supera al código, recórtalo.\n"
    "c. Autorreview con `{autorreview}` en modo autor contra origin/{base} (queda en la conversación, no se publica).\n"
    "d. {auditoria}; si no está disponible, dilo. Comprueba que existan los hooks de git (p. ej. Husky) y que se ejecuten. Nunca --no-verify.\n"
    "e. Con todo eso, pídeme el OK del commit (mensaje en español, merge de origin/{base}) y, después, otro OK para el push. Sin rebase ni force push.\n\n"
    "## Bitácora\n"
    "{bitacora}"
)

def ticket_key(pr_title, branch):
    m = TICKET.search(pr_title) or TICKET.search(branch.upper())
    return m.group(1) if m else None

def bitacora_note(cfg, key, wt, head, base, n):
    vault, harness = cfg.get("vaultDir"), cfg.get("harnessDir")
    if not key: return "El PR no tiene clave de ticket en el título ni en la rama: dime dónde anotarlo.", []
    if not vault: return (f"Falta `vaultDir` en la config de pr-tracker, así que no sé dónde está la bitácora de {key}. Avísame antes de seguir; no inventes una ruta."), []
    vault = Path(os.path.expanduser(vault)); f = vault / "Tickets" / key / "bitacora.md"
    adds = [str(vault)] + ([str(Path(os.path.expanduser(harness)))] if harness else [])
    if not f.exists():
        cr = f"bash {Path(os.path.expanduser(harness)) / 'scripts/crear-ticket.sh'} --apply {key} {vault}" if harness else "scripts/crear-ticket.sh del meta-harness"
        return (f"No existe la carpeta de {key} en Obsidian ({f.parent}). Pídeme OK para crearla con `{cr}` (sin sobrescribir nada) y luego anota ahí."), adds
    return (f"Registra en {f}, antes de pasar a otra cosa, con la hora de `date \"+%Y-%m-%d %H:%M\"` y el formato "
            f"`- **AAAA-MM-DD HH:MM** — [V] qué pasó y por qué` (solo [V] lo que verificaste en esta sesión, con el sha):\n"
            f"- al empezar: PR #{n}, rama {head}, worktree {wt}, base origin/{base}, qué archivos chocaban y cómo los resolviste;\n"
            f"- el resultado de cada comprobación (a–d), con la cifra de volumen de tests;\n"
            f"- el commit y el push, solo cuando yo los apruebe y se hagan (sha incluido).\n"
            f"Actualiza también el «Punto de reanudación» al inicio del archivo. Si algo no se hizo, anótalo como pendiente, no como hecho."), adds

def resolve_cmd(args):
    """resolve CUENTA URL: deja el PR en su worktree con el merge de la rama base en curso, abre VS Code en los
    archivos en conflicto y una sesión de Claude con las instrucciones para resolverlos."""
    login, url = args[0], args[1]
    cfg = load(CONFIG, {})
    o, r, n = parse_url(url)
    pr = gql(env_for(login), Q_FILES, o=o, r=r, n=n)["repository"]["pullRequest"]
    base, head = pr["baseRefName"], pr["headRefName"]
    pr_title = pr.get("title", "")
    clone = find_clone(o, r, cfg)
    g = ["git", "-C", str(clone)]
    sh(g + ["fetch", "-q", "origin", f"+refs/heads/{base}:refs/remotes/origin/{base}", f"+refs/heads/{head}:refs/remotes/origin/{head}"], timeout=120)
    wt, cur = None, None
    for line in sh(g + ["worktree", "list", "--porcelain"]).splitlines():
        if line.startswith("worktree "): cur = line[9:]
        elif line == f"branch refs/heads/{head}": wt = Path(cur); break
    if wt is None:
        wt = Path(os.path.expanduser(cfg.get("reviewDir", "~/Proyectos/worktrees"))) / f"{r}-pr{n}-fix"
        if not wt.exists(): sh(g + ["worktree", "add", "-q", "-B", head, str(wt), f"origin/{head}"], timeout=120)
    w = ["git", "-C", str(wt)]
    in_merge = subprocess.run(w + ["rev-parse", "-q", "--verify", "MERGE_HEAD"], capture_output=True).returncode == 0
    if not in_merge:
        if sh(w + ["status", "--porcelain"]).strip():
            raise RuntimeError(f"El worktree {wt} tiene cambios sin commit: guárdalos antes de resolver conflictos")
        subprocess.run(w + ["merge", "-q", "--ff-only", f"origin/{head}"], capture_output=True)  # ponerse al día con lo ya subido
        subprocess.run(w + ["merge", "--no-commit", "--no-ff", f"origin/{base}"], capture_output=True, text=True)
    files = [f for f in sh(w + ["diff", "--name-only", "--diff-filter=U"]).splitlines() if f]
    key = ticket_key(pr_title, head)
    if files:
        situacion = f"Hay un merge de origin/{base} en curso con conflictos en:\n" + "\n".join("- " + f for f in files)
    else:
        staged = [f for f in sh(w + ["diff", "--cached", "--name-only"]).splitlines() if f]
        situacion = (f"Hay un merge de origin/{base} en curso que git resolvió solo (sin conflictos) en {len(staged)} archivos, pero GitHub marca el PR con conflictos. "
                     "Lo más probable es un renombre o movimiento de archivo en este PR mientras la base editó ese mismo archivo en su ruta vieja: "
                     "GitHub lo da por conflicto y git lo resuelve aplicando la edición al archivo nuevo. "
                     "Comprueba eso, no busques conflictos que no existen: 1) git diff --cached -M --name-status para ver los renombres del merge; "
                     f"2) por cada archivo movido que la base tocó (git log --oneline $(git merge-base HEAD origin/{base})..origin/{base} -- <ruta vieja>), "
                     "confirma que la edición de la base quedó en la ruta nueva (git diff --cached <ruta nueva>); "
                     "3) revisa que ningún import o ruta de la base siga apuntando al lugar viejo. "
                     "Si todo cuadra, con mi OK se confirma el merge y se sube, y GitHub recalcula al ver el merge hecho.")
        if not staged:
            subprocess.run(w + ["merge", "--abort"], capture_output=True)
            print(f"#{n} ya está al día con origin/{base}: no hay nada que mezclar"); return
    note, adds = bitacora_note(cfg, key, wt, head, base, n)
    editor = cfg.get("editor", "code")
    if os.environ.get("PR_TRACKER_DRY"): editor = "true"
    subprocess.Popen([editor, "-n", str(wt)] + [str(wt / f) for f in files[:15]],
                     start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    msg = RESOLVE_PROMPT.format(o=o, r=r, n=n, head=head, base=base, situacion=situacion, bitacora=note,
                                autorreview=cfg.get("selfReviewPrompt", "/code-review"),
                                auditoria=cfg.get("auditCommand", "La auditoría de seguridad del repo, si tiene una"))
    extra = "".join(f" --add-dir {shlex.quote(a)}" for a in adds)
    launch_terminal(cfg, wt, "claude " + shlex.quote(msg) + extra)
    print(f"#{n}: " + (f"{len(files)} archivos en conflicto" if files else "merge limpio, listo para confirmar") + f" abierto en {editor} y en la terminal")

def review_cmd(args):
    login, url = args[0], args[1]
    mode = args[2] if len(args) > 2 else "code"
    cfg = load(CONFIG, {})
    o, r, n, pr, base, wt = prepare_wt(login, url, cfg)
    changed = [f for f in sh(["git", "-C", str(wt), "diff", "--name-only", f"origin/{base}...HEAD"]).splitlines() if f]
    since = None
    try:
        lr = my_last_review(login, o, r, n)
        if lr and have_commit(["git", "-C", str(wt)], lr[1]):
            since = lr[1]
            news = set(sh(["git", "-C", str(wt), "diff", "--name-only", f"{since}..HEAD"]).splitlines())
            changed = [f for f in changed if f in news]   # lo del PR que cambió desde mi review (sin lo que solo entró de la base)
    except Exception:
        since = None
    ordered = reading_order(changed)
    viewed = {f["path"] for f in pr["files"]["nodes"] if f["viewerViewedState"] == "VIEWED"}
    order_file = HOME / ".cache/pr-tracker" / f"review-{r}-{n}.order"
    order_file.parent.mkdir(parents=True, exist_ok=True)
    order_file.write_text("\n".join(ordered) + "\n")
    if mode == "list":
        for f in ordered: print(("  visto " if f in viewed else "        ") + f"[{read_rank(f)}] {f}")
        print((f"desde tu review ({since[:8]}): " if since else "") + f"{len(ordered)} archivos, {len(viewed)} vistos; worktree: {wt}")
    elif mode == "git":
        editor = cfg.get("editor", "code")
        subprocess.Popen([editor, str(wt)], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"#{n} abierto en {editor}: Ctrl+Shift+G para ver los cambios" + (f". Desde tu review: git diff {since[:8]}..HEAD" if since else ""))
    elif mode == "term":
        shell = os.environ.get("SHELL", "sh")
        if since:
            rng = f"{since}..HEAD -- " + " ".join(shlex.quote(f) for f in ordered)
        else:
            rng = f"origin/{base}...HEAD"
        cmd = (f"git -C {wt} -c core.pager='delta --line-numbers' diff -O{order_file} {rng}; "
               f"exec {shell}")
        term = cfg.get("terminal", "kitty")
        argv = [term, "--directory", str(wt), "sh", "-c", cmd] if term == "kitty" else [term, "-e", "sh", "-c", cmd]
        subprocess.Popen(argv, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"Diff de #{n} abierto en la terminal ({len(ordered)} archivos" + (f", solo lo nuevo desde tu review {since[:8]}" if since else "") + ")")
    else:
        todo = [f for f in ordered if read_rank(f) < 9 and (since or f not in viewed)][:25]
        editor = cfg.get("editor", "code")
        subprocess.Popen([editor, "-n", str(wt)] + [str(wt / f) for f in todo if (wt / f).exists()],
                         start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"#{n} abierto en {editor}: {len(todo)} archivos por leer" + (f" (solo lo nuevo desde tu review {since[:8]})" if since else f", {len(viewed)} ya vistos"))


# ---------- code review en lote ----------
REVIEWS = DATA / "reviews"
RSTATE = REVIEWS / "state.json"
BATCH_PID = REVIEWS / "batch.pid"
_state_lock = threading.Lock()

BATCH_PROMPT = (
    "MODO LOTE, sin interacción. Revisa el PR {o}/{r}#{n} ({url}) con tu método (dos pasadas, ingeniería sin leer antes la "
    "especificación) y el formato de plantillas/review.md.\n"
    "Reglas de este modo: no hagas preguntas ni pidas OK; no publiques nada (ni gh pr review ni comentarios ni Jira); "
    "no escribas en Obsidian ni crees carpetas de ticket; no ejecutes build, tests ni instales dependencias (decláralo en "
    "«No verifiqué»: es una primera pasada); no lances subagentes: revisa tú solo con todos los ángulos; la copia aparte del repo "
    "es un worktree de lectura. Tu respuesta final es el borrador completo en Markdown y nada más."
)
BATCH_RE_PROMPT = (
    "MODO LOTE, sin interacción. RE-REVISIÓN del PR {o}/{r}#{n} ({url}). Mi review anterior ({estado}) fue sobre el commit {old} y el PR "
    "ya está en {new}. Revisa solo lo que cambió desde mi review (git diff {old}..{new}, sin lo que entró de la base por un merge; si {old} "
    "ya no existe por un rebase, usa git range-diff) con tu método de re-revisión y el formato de plantillas/review.md (ronda 2 o más): "
    "cada punto de mi review anterior queda Corregido, Sigue o Declarado, con la línea, y después solo lo nuevo del delta.\n"
    "Reglas de este modo: no hagas preguntas ni pidas OK; no publiques nada (ni gh pr review ni comentarios ni Jira); "
    "no escribas en Obsidian ni crees carpetas de ticket; no ejecutes build, tests ni instales dependencias (decláralo en "
    "«No verifiqué»); no lances subagentes: el delta es chico, revisa tú solo con todos los ángulos; la copia aparte del repo "
    "es un worktree de lectura. Tu respuesta final es el borrador completo en Markdown y nada más."
)
BATCH_ALLOWED = ["Read", "Glob", "Grep", "Bash(git:*)", "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)",
                 "Bash(gh pr list:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(wc:*)", "mcp__codegraph",
                 "mcp__claude_ai_Atlassian_MCP__getJiraIssue", "mcp__claude_ai_Atlassian_MCP__listJiraIssueComments",
                 "mcp__claude_ai_Atlassian_MCP__searchJiraIssuesUsingJql"]
BATCH_DENIED = ["Edit", "Write", "NotebookEdit", "Bash(git push:*)", "Bash(gh pr review:*)", "Bash(gh pr comment:*)",
                "Bash(gh pr merge:*)", "Bash(gh pr edit:*)", "Bash(gh pr close:*)", "Bash(gh api:*)"]

def batch_running():
    try:
        os.kill(int(BATCH_PID.read_text()), 0); return True
    except Exception: return False

def reviews_view():
    """Estado de los reviews en lote; lo que quedó «en curso» sin proceso vivo se marca como interrumpido."""
    st = load(RSTATE, {})
    if not batch_running():
        for v in st.values():
            if v.get("status") in ("queued", "running"): v["status"] = "error"; v["error"] = "interrumpido"
    return st

def set_review(url, **kw):
    with _state_lock:
        st = load(RSTATE, {})
        st.setdefault(url, {}).update(kw, updated=now().isoformat())
        save(RSTATE, st)

def batch_cmd(args):
    pairs = list(zip(args[0::2], args[1::2]))
    cfg = load(CONFIG, {})
    if not pairs: print("No hay PRs para revisar"); sys.exit(1)
    if not cfg.get("harnessDir"): print("Falta harnessDir en config.json (carpeta con el agente de review)"); sys.exit(1)
    if batch_running(): print("Ya hay un lote en curso"); sys.exit(1)
    st = load(RSTATE, {})
    for acct, url in pairs:
        if st.get(url, {}).get("status") != "done":
            st[url] = {"status": "queued", "account": acct, "updated": now().isoformat()}
    save(RSTATE, st)
    p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "batch-run"] + args, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    BATCH_PID.parent.mkdir(parents=True, exist_ok=True); BATCH_PID.write_text(str(p.pid))
    print(f"Lote iniciado: {len(pairs)} PRs, {int(cfg.get('batchParallel', 3))} a la vez")

def batch_stop():
    try: os.killpg(int(BATCH_PID.read_text()), signal.SIGTERM)
    except Exception: pass
    st = load(RSTATE, {})
    for v in st.values():
        if v.get("status") in ("queued", "running"): v["status"] = "error"; v["error"] = "cancelado"
    save(RSTATE, st)
    BATCH_PID.unlink(missing_ok=True)
    print("Lote cancelado")

def batch_run(args):
    pairs = list(zip(args[0::2], args[1::2]))
    cfg = load(CONFIG, {})
    harness = Path(os.path.expanduser(cfg["harnessDir"]))
    agent = cfg.get("reviewAgent", "review")
    dirs = [os.path.expanduser(d) for d in cfg.get("batchAddDirs", ["~/Proyectos"])]
    REVIEWS.mkdir(parents=True, exist_ok=True)
    results = {"done": 0, "error": 0, "skip": 0}

    def job(pair):
        acct, url = pair
        o, r, n = parse_url(url)
        try:
            sha = gql(env_for(acct), Q_ONE, o=o, r=r, n=n)["repository"]["pullRequest"]["headRefOid"]
            prev = load(RSTATE, {}).get(url, {})
            if prev.get("status") == "done" and prev.get("sha") == sha and Path(prev.get("draft", "")).exists():
                results["skip"] += 1; return
            set_review(url, status="running", sha=sha, account=acct, startedAt=now().isoformat(), error=None)
            cmd = ["claude", "-p", "--agent", agent, "--output-format", "text"]
            if cfg.get("batchModel"): cmd += ["--model", cfg["batchModel"]]
            cmd += ["--add-dir"] + dirs + ["--allowedTools"] + BATCH_ALLOWED + ["--disallowedTools"] + BATCH_DENIED
            try: lr = my_last_review(acct, o, r, n)
            except Exception: lr = None
            if lr:
                prompt = BATCH_RE_PROMPT.format(o=o, r=r, n=n, url=url, estado=STATE_ES.get(lr[0], lr[0]), old=lr[1][:8], new=lr[2][:8])
            else:
                prompt = BATCH_PROMPT.format(o=o, r=r, n=n, url=url)
            cmd += ["--", prompt]
            res = subprocess.run(cmd, cwd=harness, capture_output=True, text=True, timeout=int(cfg.get("batchTimeoutMin", 30)) * 60)
            text = res.stdout.strip()
            if res.returncode != 0 or len(text) < 300:
                raise RuntimeError((res.stderr or text or "respuesta vacía").strip()[:160])
            draft = REVIEWS / f"{r}-pr{n}-{sha[:7]}.md"
            draft.write_text(text + "\n")
            set_review(url, status="done", draft=str(draft), finishedAt=now().isoformat())
            results["done"] += 1
        except Exception as e:
            set_review(url, status="error", error=str(e)[:160]); results["error"] += 1

    with ThreadPoolExecutor(max_workers=max(1, int(cfg.get("batchParallel", 3)))) as ex:
        list(ex.map(job, pairs))
    BATCH_PID.unlink(missing_ok=True)
    try:
        subprocess.run(["notify-send", "-a", "Mis PRs", "Reviews en lote terminados",
                        f"{results['done']} borradores listos, {results['error']} con error, {results['skip']} ya al día"], timeout=10)
    except Exception: pass


# ---------- principal ----------
# ---------- reportes ----------
# A quién le toca cada PR. Todo se mide contra el ÚLTIMO commit del PR: una review solo cuenta si es sobre ese commit.
# El orden del equipo es compañero primero y TL al final, así que:
#   Mis PRs (autor: yo)
#     · un review mío no aplica; si el TL ya aprobó el último commit, está listo y no se lista;
#     · observado (cambios pedidos vigentes), conflictos o CI fallando       -> me toca a mí
#     · el compañero no tiene un approve del último commit                   -> le toca al compañero
#         (sin ninguna review, o con una vieja: re-review)
#     · el compañero aprobó el último commit y el TL no                      -> le toca al TL
#         (el TL pidió cambios sobre ese mismo commit: espera al autor, no se lista)
#   PRs que revisé (autor: otro, abiertos y no borrador)
#     · mi review no es sobre el último commit (hay commits nuevos)          -> me toca a mí
#     · pedí cambios sobre el último commit                                   -> le toca al autor
#     · aprobé el último commit y el TL no tiene un approve vigente           -> le toca al TL
_MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]

def _cuando(iso, ahora=None):
    """«hoy a las 17:12», «ayer», «el 17» (o «el 17 de octubre» si es de otro mes)."""
    d = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone()
    hoy = (ahora or datetime.now()).astimezone().date()
    if d.date() == hoy: return f"hoy a las {d:%H:%M}"
    if (hoy - d.date()).days == 1: return "ayer"
    return f"el {d.day}" + ("" if (d.year, d.month) == (hoy.year, hoy.month) else f" de {_MESES[d.month - 1]}")

def _linea(p, nota=""):
    m = re.match(r"^\s*\w+(?:\(([^)]*)\))?!?:\s*(.+)$", p["title"])
    desc = f"{m.group(1)} ({m.group(2)})" if m and m.group(1) and TICKET.fullmatch(m.group(1).strip()) else p["title"]
    return f"- {p['repo']}#{p['number']}, {desc}" + (f". {nota}" if nota else "") + f": {p['url']}"

def _review_de(p, login):
    for r in p.get("reviews") or []:
        if r["login"].lower() == login.lower(): return r
    return None

def report_reviews(data, cfg, ahora=None):
    """«Estado de los code review y de mis PRs»: qué le toca a cada persona, listo para pegar en Slack."""
    tl = cfg.get("tlLogin", "")
    peer = cfg.get("peerLogin", "")
    names = cfg.get("people", {})
    nm = lambda login, otro: names.get(login) or login or otro
    tl_n, peer_n = nm(tl, "el TL"), nm(peer, "el compañero")
    VERBO = {"APPROVED": "Aprobó", "CHANGES_REQUESTED": "Pidió cambios", "COMMENTED": "Comentó"}

    tl_revisados, peer_sin, peer_re, tl_mios, mios = [], [], [], [], []
    for p in data.get("prs", []):
        if p.get("status") == "draft": continue
        rt = _review_de(p, tl) if tl else None
        if rt and rt["state"] == "APPROVED" and rt["current"]: continue          # listo
        if p["status"] in ("observado", "conflicto", "ci"):
            mios.append(_linea(p, p.get("label", ""))); continue
        rp = _review_de(p, peer) if peer else next((r for r in p.get("reviews", []) if r["login"] != tl and r["login"] != p["account"]), None)
        if not rp or rp["state"] == "DISMISSED":
            peer_sin.append(_linea(p)); continue
        if not rp["current"]:
            extra = "" if rp["state"] == "APPROVED" else f"Su review fue «{VERBO.get(rp['state'], rp['state']).lower()}», antes de los últimos commits"
            peer_re.append(_linea(p, extra)); continue
        if rp["state"] == "CHANGES_REQUESTED":                                   # observado vigente (ya cubierto arriba)
            mios.append(_linea(p, "Observado")); continue
        if rt and rt["state"] == "CHANGES_REQUESTED" and rt["current"]: continue  # el TL espera al autor
        nota = ""
        if rt: nota = f"{VERBO.get(rt['state'], rt['state'])} {_cuando(rt['at'], ahora)}" + (", sobre un commit anterior" if rt["state"] == "APPROVED" else "")
        tl_mios.append(_linea(p, nota))
    for p in data.get("reviewed", []):
        if p.get("prState") != "OPEN" or p.get("isDraft") or p.get("myState") != "APPROVED" or p.get("newCommits"): continue
        rt = _review_de(p, tl) if tl else None
        if rt and rt["current"] and rt["state"] in ("APPROVED", "CHANGES_REQUESTED"): continue   # ya aprobó, o espera al autor
        nota = ""
        if rt: nota = f"{VERBO.get(rt['state'], rt['state'])} {_cuando(rt['at'], ahora)}" + (", sobre un commit anterior" if rt["state"] == "APPROVED" else "")
        tl_revisados.append(_linea(p, nota))

    out = ["Buenas el estado de los code review y de mis prs que quedan pendientes a revisar"]
    n = 0
    def sec(titulo, bloques):
        nonlocal n
        bloques = [(h, l) for h, l in bloques if l]
        if not bloques: return
        n += 1
        out.append(f"\n{n}. {titulo}")
        for h, l in bloques:
            if h: out.append(f"\n{h}")
            out.extend(l)
    sec(f"{tl_n} falta tu review", [("", tl_revisados)])
    sec(f"Mis PRs que falta que revise {peer_n}", [("Sin ninguna review todavía:", peer_sin), (f"Su review es de un commit anterior (re-review de {peer_n}):", peer_re)])
    sec(f"Mis PRs que falta que revise {tl_n}", [("", tl_mios)])
    sec("Por atender de mi lado antes de pedir review (observados, conflictos o CI)", [("", mios)])
    if n == 0: out.append("\nNo queda nada pendiente.")
    return "\n".join(out)

_ORDEN_ETAPA = {4: 0, 3: 1, 2: 2, 1: 3, 5: 4, 9: 5}

def report_tickets(tickets, prs, merged, cfg, ahora=None):
    """«Estado de mis tickets» para el TL: resumen por estado de Jira y, por ticket, sus PRs (mergeados o abiertos con su situación)."""
    tl = cfg.get("tlLogin", "")
    names = cfg.get("people", {})
    tl_n = names.get(tl) or tl or "TL"
    hoy = (ahora or datetime.now()).astimezone()
    por_ticket = {}
    for p in merged:
        k = ticket_of({"title": p["title"], "branch": ""})
        if k: por_ticket.setdefault(k, {})[(p["repo"], p["number"])] = f"{p['repo']}#{p['number']}"
    for p in prs:
        k = ticket_of(p)
        if not k: continue
        pend = [names.get(x) or x for x in p.get("requested", []) if x and x != p.get("author")]
        nota = p.get("label", "")
        if p.get("status") == "review" and pend: nota += " de " + " y ".join(pend)
        por_ticket.setdefault(k, {})[(p["repo"], p["number"])] = f"{p['repo']}#{p['number']} ({nota.lower()})" if nota else f"{p['repo']}#{p['number']}"
    grupos = {}
    for t in tickets:
        # los tableros nombran distinto lo mismo: se agrupa «en curso» y «por hacer»
        g = {1: "IN PROGRESS", 9: "TO DO / BACKLOG"}.get(t["stage"], t["status"])
        grupos.setdefault(g, []).append(t)
    orden = sorted(grupos, key=lambda s: (_ORDEN_ETAPA.get(grupos[s][0]["stage"], 9), s))
    out = [f"@{tl_n}, te comparto el estado actualizado de mis tickets al {hoy.day}-{_MESES[hoy.month - 1][:3]}.",
           "", "RESUMEN GENERAL", "", f"Tengo {len(tickets)} tickets abiertos:", ""]
    out += [f"• {len(grupos[s])} en {s.upper()}" for s in orden]
    for n, s in enumerate(orden, 1):
        out += ["", f"{n}. {s.upper()} ({len(grupos[s])})", ""]
        for t in grupos[s]:
            prs_t = ", ".join(por_ticket.get(t["key"], {}).values())
            out.append(f"• {t['key']} ({t['summary']})" + (f": {prs_t}" if prs_t else ""))
    return "\n".join(out)

def report_tickets_review(prs, cfg, ahora=None):
    """Tickets con PRs que esperan review o re-review, por persona y en orden (compañero primero, TL al final). Para pedir review."""
    tl, peer = cfg.get("tlLogin", ""), cfg.get("peerLogin", "")
    names = cfg.get("people", {})
    tl_n, peer_n = names.get(tl) or tl or "el TL", names.get(peer) or peer or "el compañero"
    secs = {"peer_sin": {}, "peer_re": {}, "tl": {}}
    for p in prs:
        if p.get("status") in ("draft", "observado", "conflicto", "ci"): continue
        rt = _review_de(p, tl) if tl else None
        if rt and rt["current"] and rt["state"] in ("APPROVED", "CHANGES_REQUESTED"): continue
        rp = _review_de(p, peer) if peer else next((r for r in p.get("reviews", []) if r["login"] != tl and r["login"] != p["account"]), None)
        if not rp or rp["state"] == "DISMISSED": k = "peer_sin"
        elif not rp["current"]: k = "peer_re"
        elif rp["state"] == "CHANGES_REQUESTED": continue
        else: k = "tl"
        t = ticket_of(p) or "Sin ticket"
        secs[k].setdefault(t, {"titulo": p["title"], "prs": []})["prs"].append(f"{p['repo']}#{p['number']}: {p['url']}")
    def desc(t, d):
        m = re.match(r"^\s*\w+(?:\([^)]*\))?!?:\s*(.+)$", d["titulo"])
        return f"- {t} ({m.group(1) if m else d['titulo']}): " + ", ".join(d["prs"])
    out = ["Buenas, estos son mis tickets que esperan review:"]
    n = 0
    for k, titulo in (("peer_sin", f"Falta review de {peer_n}"), ("peer_re", f"Falta re-review de {peer_n} (subí cambios después de su review)"), ("tl", f"Falta review de {tl_n} (ya pasó por {peer_n})")):
        if not secs[k]: continue
        n += 1
        out += ["", f"{n}. {titulo}", ""] + [desc(t, d) for t, d in secs[k].items()]
    if n == 0: out.append("\nNo queda ninguno pendiente.")
    return "\n".join(out)

def report_revisados(reviewed, cfg, ahora=None, horas=24):
    """Los PRs que revisé en las últimas `horas`: cuáles aprobé y en cuáles pedí cambios, con su link."""
    ahora = (ahora or datetime.now()).astimezone()
    tl = cfg.get("tlLogin", "")
    names = cfg.get("people", {})
    grupos = {"APPROVED": [], "CHANGES_REQUESTED": [], "COMMENTED": []}
    for p in sorted(reviewed, key=lambda x: x.get("reviewedAt") or ""):
        at = p.get("reviewedAt")
        if not at or p.get("myState") not in grupos: continue
        if (ahora - datetime.fromisoformat(at.replace("Z", "+00:00")).astimezone()).total_seconds() > horas * 3600: continue
        aut = names.get(p.get("author")) or p.get("author", "")
        grupos[p["myState"]].append(_linea(p, f"De {aut}, {_cuando(at, ahora)}" if aut else _cuando(at, ahora)))
    out = [f"Buenas, esto es lo que revisé en las últimas {horas} horas:"]
    n = 0
    for k, t in (("APPROVED", "Aprobé estos"), ("CHANGES_REQUESTED", "Pedí cambios en estos"), ("COMMENTED", "Solo dejé comentarios en estos")):
        if not grupos[k]: continue
        n += 1
        out += ["", f"{n}. {t}", ""] + grupos[k]
    if n == 0: out.append("\nNo revisé ningún PR en ese tiempo.")
    return "\n".join(out)

def report_aprobados_tl(reviewed, cfg, ahora=None):
    """Tickets cuyos PRs ya aprobé (sobre el último commit) y que aún no pasan por el TL, agrupados por ticket."""
    tl = cfg.get("tlLogin", "")
    names = cfg.get("people", {})
    tl_n = names.get(tl) or tl or "el TL"
    VERBO = {"APPROVED": "aprobó", "CHANGES_REQUESTED": "pidió cambios", "COMMENTED": "comentó"}
    tickets = {}
    for p in reviewed:
        if p.get("prState") != "OPEN" or p.get("isDraft") or p.get("myState") != "APPROVED" or p.get("newCommits"): continue
        rt = _review_de(p, tl) if tl else None
        if rt and rt["current"] and rt["state"] in ("APPROVED", "CHANGES_REQUESTED"): continue
        nota = ""
        if rt: nota = f"{tl_n} {VERBO.get(rt['state'], rt['state'])} {_cuando(rt['at'], ahora)}" + (", sobre un commit anterior" if rt["state"] == "APPROVED" else "")
        k = ticket_of(p) or "Sin ticket"
        t = tickets.setdefault(k, {"titulo": p["title"], "prs": []})
        t["prs"].append(f"{p['repo']}#{p['number']}" + (f" ({nota})" if nota else "") + f": {p['url']}")
    out = [f"{tl_n}, estos tickets ya los aprobé y falta tu review:"]
    for k, d in tickets.items():
        m = re.match(r"^\s*\w+(?:\([^)]*\))?!?:\s*(.+)$", d["titulo"])
        out += ["", f"- {k} ({m.group(1) if m else d['titulo']})"] + [f"  • {x}" for x in d["prs"]]
    if not tickets: out.append("\nNo hay ninguno pendiente.")
    return "\n".join(out)

def report_cmd(args):
    """report TIPO: imprime el reporte (hoy: «revisiones»), con datos frescos de GitHub."""
    kind = args[0] if args else "revisiones"
    cfg = load(CONFIG, {})
    if kind not in ("revisiones", "tickets", "tickets-review", "revisados", "aprobados-tl"): print("Reporte desconocido: " + kind); sys.exit(1)
    raw = subprocess.run([sys.executable, os.path.abspath(__file__)], capture_output=True, text=True, timeout=180).stdout
    data = json.loads(raw)
    if data.get("error"): print("Error: " + str(data["error"])[:200]); sys.exit(1)
    if kind == "revisiones":
        print(report_reviews(data, cfg)); return
    if kind == "aprobados-tl":
        print(report_aprobados_tl(data.get("reviewed", []), cfg)); return
    if kind == "revisados":
        print(report_revisados(data.get("reviewed", []), cfg)); return
    if kind == "tickets-review":
        print(report_tickets_review(data.get("prs", []), cfg)); return
    here = os.path.dirname(os.path.abspath(__file__))
    script = next((os.path.join(here, n) for n in ("my-tickets", "my-tickets.py") if os.path.exists(os.path.join(here, n))), None)
    if not script: print("Error: no encuentro my-tickets"); sys.exit(1)
    tj = json.loads(subprocess.run([sys.executable, script], capture_output=True, text=True, timeout=120).stdout)
    if tj.get("error"): print("Error: " + str(tj["error"])[:200]); sys.exit(1)
    q = subprocess.run(["gh", "search", "prs", "--author", "@me", "--merged", "--limit", "300", "--json", "repository,number,title"], capture_output=True, text=True, timeout=60).stdout
    merged = [{"repo": x["repository"]["name"], "number": x["number"], "title": x["title"]} for x in json.loads(q or "[]")]
    print(report_tickets(tj["tickets"], data.get("prs", []), merged, cfg))


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "watch":
        watch_cmd(argv[1:]); return
    if argv and argv[0] == "report":
        try: report_cmd(argv[1:])
        except Exception as e:
            print("Error: " + str(e)[:200]); sys.exit(1)
        return
    if argv and argv[0] == "rereview":
        try: rereview(argv[1], argv[2])
        except subprocess.CalledProcessError as e:
            print("Error: " + (e.stderr or str(e)).strip()[:200]); sys.exit(1)
        return

    if argv and argv[0] in ("batch", "batch-run", "batch-stop"):
        try:
            {"batch": batch_cmd, "batch-run": batch_run}.get(argv[0], lambda a: batch_stop())(argv[1:])
        except Exception as e:
            print("Error: " + str(e)[:200]); sys.exit(1)
        return
    if argv and argv[0] == "codereview":
        try: codereview_cmd(argv[1:])
        except subprocess.CalledProcessError as e:
            print("Error: " + (e.stderr or str(e)).strip()[:200]); sys.exit(1)
        except Exception as e:
            print("Error: " + str(e)[:200]); sys.exit(1)
        return
    if argv and argv[0] == "resolve":
        try: resolve_cmd(argv[1:])
        except subprocess.CalledProcessError as e:
            print("Error: " + (e.stderr or str(e)).strip()[:200]); sys.exit(1)
        except Exception as e:
            print("Error: " + str(e)[:200]); sys.exit(1)
        return
    if argv and argv[0] == "review":
        try: review_cmd(argv[1:])
        except subprocess.CalledProcessError as e:
            print("Error: " + (e.stderr or str(e)).strip()[:200]); sys.exit(1)
        except Exception as e:
            print("Error: " + str(e)[:200]); sys.exit(1)
        return

    cfg = load(CONFIG, {})
    stale_days = int(cfg.get("staleDays", 2))
    merged_days = int(cfg.get("mergedDays", 5))
    reviewed_days = int(cfg.get("reviewedDays", 14))
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
        rs = (now() - timedelta(days=reviewed_days)).strftime("%Y-%m-%d")
        try: rv = gql(envs[login], Q_REVIEWED, q=f"is:pr reviewed-by:@me -author:@me archived:false updated:>={rs} sort:updated-desc")["search"]["nodes"]
        except Exception: rv = []
        return login, d["search"]["nodes"], r["search"]["nodes"], m["search"]["nodes"], rv

    prs, review, merged, reviewed = [], [], [], []
    with ThreadPoolExecutor(max_workers=6) as ex:
        futs = {l: ex.submit(per_account, l) for l in ok}
        watch_items = load(WATCH, [])
        wfut = [ex.submit(fetch_watch, i, ok, envs) for i in watch_items]
        for l, f in futs.items():
            try:
                _, mine, rev, mer, rvd = f.result()
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
            LBL = {"APPROVED": "Aprobaste", "CHANGES_REQUESTED": "Pediste cambios", "COMMENTED": "Comentaste", "DISMISSED": "Review descartado"}
            for n in rvd:
                v = (n or {}).get("viewerLatestReview")
                if not v: continue
                d = base(n, l)
                merged_pr = bool(n.get("mergedAt"))
                d.update({"status": "mergeado" if merged_pr else ("aprobado" if v["state"] == "APPROVED" else "review"),
                          "label": LBL.get(v["state"], "Revisado"), "myState": v["state"], "reviewedAt": v["submittedAt"],
                          "reviewedDaysAgo": days_since(v["submittedAt"]),
                          "prState": "MERGED" if merged_pr else n["state"],
                          "newCommits": bool((v.get("commit") or {}).get("oid")) and v["commit"]["oid"] != n.get("headRefOid", "") and n["state"] == "OPEN"})
                fl = n.get("files") or {}
                d["filesTotal"] = fl.get("totalCount", 0)
                d["filesViewed"] = sum(1 for f in fl.get("nodes", []) if f["viewerViewedState"] == "VIEWED")
                d["isDraft"] = bool(n.get("isDraft"))
                reviewed.append(d)
            for n in rev:
                if not n: continue
                d = base(n, l); d.update({"status": "review", "label": "Pide tu review"})
                fl = (n.get("files") or {})
                d["filesTotal"] = fl.get("totalCount", 0)
                d["filesViewed"] = sum(1 for f in fl.get("nodes", []) if f["viewerViewedState"] == "VIEWED")
                review.append(d)
        watching = [f.result() for f in wfut]

    # Un PR que ya revisaste y recibió commits después de tu review vuelve a «Para revisar»: GitHub no te lo
    # vuelve a pedir solo, y sin esto el cambio pasa sin que nadie lo mire.
    have = {p["url"] for p in review}
    for p in reviewed:
        if p["newCommits"] and not p["isDraft"] and p["myState"] != "DISMISSED" and p["url"] not in have:
            d = dict(p); d.update({"status": "review", "label": "Commits nuevos tras tu review", "afterReview": True})
            review.append(d)
    # Jira (opcional): estado del ticket de cada PR mío
    for p in prs + merged + review:
        k = TICKET.search(p["title"]) or TICKET.search(p["branch"].upper())
        p["ticket"] = k.group(1) if k else None
    conf = jira_conf()
    if conf:
        keys = {}
        for p in prs + merged:
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
    reviewed.sort(key=lambda p: p["reviewedAt"], reverse=True)

    groups = build_groups(prs, merged)
    view = mine_view(prs, groups)

    # Recordatorio diario de estancados (solo el widget consume el aviso)
    remind = []
    if "--widget" in argv:
        st = load(STATE, {})
        today = datetime.now().strftime("%Y-%m-%d")
        stale = [p for p in prs if p["stale"]] + [p for p in review if p["stale"]]
        if stale and st.get("lastReminder") != today and datetime.now().hour >= 9:
            remind = [{"repo": p["repo"], "number": p["number"], "idleDays": p["idleDays"]} for p in stale]
            st["lastReminder"] = today; save(STATE, st)

    print(json.dumps({"error": "; ".join(errors) or None, "prs": prs, "review": review, "merged": merged, "reviewed": reviewed, "mineView": view, "groups": groups, "watching": watching,
                      "remind": remind, "reviews": reviews_view(), "batchRunning": batch_running(), "accounts": logins, "failed": failed, "jira": bool(conf), "staleDays": stale_days, "mergedDays": merged_days, "reviewedDays": reviewed_days, "tlLogin": cfg.get("tlLogin", "")}))

main()

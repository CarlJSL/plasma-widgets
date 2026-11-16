#!/usr/bin/env python3
"""Imprime en JSON mis PRs abiertos con su estado (review, CI, conflictos)."""
import json, os, subprocess, sys

QUERY = """
query {
  search(query: "is:pr is:open author:@me archived:false sort:updated-desc", type: ISSUE, first: 50) {
    nodes { ... on PullRequest {
      number title url isDraft createdAt updatedAt mergeable reviewDecision
      baseRefName headRefName headRefOid
      latestReviews(first: 10) { nodes { state commit { oid } } }
      repository { nameWithOwner name }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    } }
  }
}
"""

def status(pr):
    ci = None
    nodes = pr["commits"]["nodes"]
    if nodes and nodes[0]["commit"]["statusCheckRollup"]:
        ci = nodes[0]["commit"]["statusCheckRollup"]["state"]
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

def accounts():
    """Cuentas de github.com logueadas en gh (todas, no solo la activa)."""
    out = subprocess.run(["gh", "auth", "status", "--json", "hosts"],
                         capture_output=True, text=True, timeout=20, check=True).stdout
    return [a["login"] for a in json.loads(out)["hosts"].get("github.com", []) if a["state"] == "success"]

def fetch(login):
    token = subprocess.run(["gh", "auth", "token", "-u", login],
                           capture_output=True, text=True, timeout=20, check=True).stdout.strip()
    env = {**os.environ, "GH_TOKEN": token}
    out = subprocess.run(["gh", "api", "graphql", "-f", f"query={QUERY}"],
                         capture_output=True, text=True, timeout=45, check=True, env=env).stdout
    return json.loads(out)["data"]["search"]["nodes"]

def main():
    prs, errors, failed, logins = [], [], [], []
    try:
        logins = accounts()
    except Exception as e:
        print(json.dumps({"error": str(e)[:200], "prs": [], "accounts": []})); return
    for login in logins:
        try:
            nodes = fetch(login)
        except Exception as e:
            errors.append(f"{login}: {str(e)[:120]}"); failed.append(login); continue
        for n in nodes:
            if not n: continue
            key, label = status(n)
            c = n["commits"]["nodes"]
            prs.append({"account": login, "repo": n["repository"]["name"], "owner": n["repository"]["nameWithOwner"],
                        "number": n["number"], "title": n["title"], "url": n["url"], "status": key, "label": label,
                        "ci": (c[0]["commit"]["statusCheckRollup"] or {}).get("state") if c else None,
                        "base": n["baseRefName"], "branch": n["headRefName"],
                        "createdAt": n["createdAt"], "updatedAt": n["updatedAt"]})
    # Más reciente primero (por creación, estable aunque subas commits); agrupado por repo,
    # con el repo del PR más nuevo arriba, para que los encabezados de sección no se repitan.
    prs.sort(key=lambda p: p["createdAt"], reverse=True)
    top = {}
    for p in prs: top.setdefault(p["owner"], p["createdAt"])
    prs.sort(key=lambda p: (top[p["owner"]], p["createdAt"]), reverse=True)
    print(json.dumps({"error": "; ".join(errors) or None, "prs": prs, "accounts": logins, "failed": failed}))

main()

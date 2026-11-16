#!/usr/bin/env python3
"""Imprime en JSON mis PRs abiertos con su estado (review, CI, conflictos)."""
import json, subprocess, sys

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
    if pr["reviewDecision"] == "CHANGES_REQUESTED":
        # Observado solo si la observación es sobre el último commit; si subí cambios después, espera re-review.
        vigente = any(r["state"] == "CHANGES_REQUESTED" and (r["commit"] or {}).get("oid") == pr["headRefOid"]
                      for r in pr["latestReviews"]["nodes"])
        if vigente:
            return "observado", "Observado"
        if pr["mergeable"] != "CONFLICTING" and ci not in ("FAILURE", "ERROR"):
            return "review", "Esperando re-review"
    if pr["mergeable"] == "CONFLICTING":
        return "conflicto", "Conflictos"
    if ci in ("FAILURE", "ERROR"):
        return "ci", "CI fallando"
    if pr["reviewDecision"] == "APPROVED":
        return "aprobado", "Aprobado"
    return "review", "Esperando review"

def main():
    try:
        out = subprocess.run(["gh", "api", "graphql", "-f", f"query={QUERY}"],
                             capture_output=True, text=True, timeout=45, check=True).stdout
        nodes = json.loads(out)["data"]["search"]["nodes"]
    except Exception as e:
        print(json.dumps({"error": str(e)[:200], "prs": []})); return
    prs = []
    for n in nodes:
        if not n: continue
        key, label = status(n)
        prs.append({"repo": n["repository"]["name"], "number": n["number"], "title": n["title"],
                    "url": n["url"], "status": key, "label": label, "ci": (n["commits"]["nodes"][0]["commit"]["statusCheckRollup"] or {}).get("state") if n["commits"]["nodes"] else None,
                    "base": n["baseRefName"], "branch": n["headRefName"], "createdAt": n["createdAt"], "updatedAt": n["updatedAt"]})
    # Más reciente primero (por creación, estable aunque subas commits); agrupado por repo,
    # con el repo del PR más nuevo arriba, para que los encabezados de sección no se repitan.
    prs.sort(key=lambda p: p["createdAt"], reverse=True)
    top = {}
    for p in prs: top.setdefault(p["repo"], p["createdAt"])
    prs.sort(key=lambda p: (top[p["repo"]], p["createdAt"]), reverse=True)
    print(json.dumps({"error": None, "prs": prs}))

main()

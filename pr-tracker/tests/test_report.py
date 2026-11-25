"""Reglas de «a quién le toca» del reporte de revisiones. Correr: python3 tests/test_report.py"""
import re, sys
from datetime import datetime
from pathlib import Path

src = (Path(__file__).parent.parent / "bin/my-prs.py").read_text()
seg = src[src.index("# ---------- reportes ----------"):src.index("def report_cmd")]
ns = {"re": re, "datetime": datetime, "TICKET": re.compile(r"\b([A-Z][A-Z0-9]{1,9}-\d+)\b")}
exec(seg, ns)
report = ns["report_reviews"]
CFG = {"tlLogin": "tl", "peerLogin": "pa", "people": {"tl": "Tele", "pa": "Pepe"}}
NOW = datetime.fromisoformat("2026-11-25T12:00:00+00:00")

def rv(login, state, current=True, at="2026-11-24T10:00:00Z"): return {"login": login, "state": state, "current": current, "at": at}
def mine(n, reviews, status="review", **kw): return dict(account="yo", repo="r", number=n, title=f"fix(ABC-{n}): cosa {n}", url=f"u{n}", status=status, reviews=reviews, **kw)
def other(n, reviews, my="APPROVED", new=False, **kw): return dict(account="yo", repo="r", number=n, title=f"fix(ABC-{n}): cosa {n}", url=f"u{n}", prState="OPEN", isDraft=False, myState=my, newCommits=new, reviews=reviews, **kw)
def run(prs=(), reviewed=()): return report({"prs": list(prs), "reviewed": list(reviewed)}, CFG, NOW)
def seccion(txt, titulo):
    i = txt.index(titulo); m = re.search(r"\n\d+\. ", txt[i + 1:]); return txt[i:i + 1 + m.start()] if m else txt[i:]

# Mis PRs
t = run(prs=[mine(1, [])]);                                          assert "Sin ninguna review todavía" in t and "#1," in t
t = run(prs=[mine(2, [rv("pa", "APPROVED", False)])]);               assert "re-review de Pepe" in t
t = run(prs=[mine(3, [rv("pa", "APPROVED")])]);                      assert "revise Tele" in seccion(t, "1. ") and "#3," in t
t = run(prs=[mine(4, [rv("pa", "APPROVED"), rv("tl", "APPROVED")])]); assert "#4," not in t and "No queda nada" in t
t = run(prs=[mine(5, [rv("pa", "APPROVED"), rv("tl", "CHANGES_REQUESTED", False)])]); assert "Pidió cambios ayer" in t   # el TL ya pidió, hubo commits: vuelve a él
t = run(prs=[mine(6, [rv("pa", "APPROVED"), rv("tl", "CHANGES_REQUESTED")])]);          assert "#6," not in t               # espera al autor
t = run(prs=[mine(7, [rv("pa", "APPROVED", False), rv("tl", "APPROVED", False)])]);     assert "re-review de Pepe" in t and "revise Tele" not in t   # primero el compañero
t = run(prs=[mine(8, [rv("pa", "CHANGES_REQUESTED")], status="observado")]);            assert "Por atender" in t
t = run(prs=[mine(9, [], status="draft")]);                                              assert "#9," not in t
# PRs que revisé
t = run(reviewed=[other(10, [])]);                                   assert "Tele falta tu review" in t and "#10," in t
t = run(reviewed=[other(11, [], new=True)]);                         assert "#11," not in t                       # me toca a mí
t = run(reviewed=[other(12, [], my="CHANGES_REQUESTED")]);           assert "#12," not in t                       # espera al autor
t = run(reviewed=[other(13, [rv("tl", "APPROVED")])]);               assert "#13," not in t
t = run(reviewed=[other(14, [rv("tl", "APPROVED", False)])]);        assert "Aprobó ayer, sobre un commit anterior" in t
t = run(reviewed=[other(15, [rv("tl", "CHANGES_REQUESTED", False, "2026-11-25T08:00:00Z")])]); assert "Pidió cambios hoy a las" in t
print("ok")

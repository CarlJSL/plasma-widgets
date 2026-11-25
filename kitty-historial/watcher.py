"""Gancho de kitty: anota en un JSONL cuándo se abre y se cierra cada terminal (ventana), su carpeta, su rama de git
y los comandos que corre (requiere shell_integration). Nunca debe romper kitty: todo va dentro de try/except."""
import json
import os
import time
from pathlib import Path

LOG = Path(os.environ.get("KITTY_HISTORIAL_LOG", Path.home() / ".local/share/kitty-historial/events.jsonl"))
_seen = set()
_cwd = {}


def _branch(cwd):
    try:
        p = Path(cwd)
        for d in [p, *p.parents]:
            head = d / ".git" / "HEAD"
            if head.is_file():
                t = head.read_text().strip()
                return t.removeprefix("ref: refs/heads/") if t.startswith("ref:") else t[:8]
    except Exception:
        pass
    return ""


def _write(window, ev, **kw):
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        rec = {"t": round(time.time(), 2), "pid": os.getpid(), "win": window.id, "ev": ev, **kw}
        with LOG.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _cwd_of(window):
    try:
        return window.cwd_of_child or _cwd.get(window.id, "")
    except Exception:
        return _cwd.get(window.id, "")


def _ensure_open(window):
    key = (os.getpid(), window.id)
    if key in _seen:
        return
    _seen.add(key)
    cwd = _cwd_of(window)
    _write(window, "open", cwd=cwd, branch=_branch(cwd), title=getattr(window, "title", "") or "")


def on_resize(boss, window, data):
    try: _ensure_open(window)
    except Exception: pass


def on_cwd_change(boss, window, data):
    try:
        _ensure_open(window)
        cwd = data.get("cwd", "")
        if cwd and cwd != _cwd.get(window.id):
            _cwd[window.id] = cwd
            _write(window, "cwd", cwd=cwd, branch=_branch(cwd))
    except Exception: pass


def on_cmd_startstop(boss, window, data):
    try:
        _ensure_open(window)
        if data.get("is_start"):
            cwd = _cwd_of(window)
            _write(window, "cmd", cmd=data.get("cmdline", ""), cwd=cwd, branch=_branch(cwd))
        else:
            _write(window, "end")
    except Exception: pass


def on_close(boss, window, data):
    try:
        _ensure_open(window)
        _write(window, "close", cwd=_cwd_of(window), reason=data.get("reason", ""), cause=data.get("cause", ""))
        _seen.discard((os.getpid(), window.id))
        _cwd.pop(window.id, None)
    except Exception: pass

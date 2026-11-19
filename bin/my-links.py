#!/usr/bin/env python3
"""my-links: lista de links guardados para el widget «Mis links».

Uso:
  my-links                          JSON con todos los links
  my-links add URL [título] [grupo] guardar un link (sin título usa el dominio)
  my-links rm ID                    borrar un link
  my-links move ID GRUPO            cambiar de grupo ("" lo deja sin grupo)
"""
import json, re, sys, uuid
from pathlib import Path
from urllib.parse import urlparse

FILE = Path.home() / ".local/share/pr-tracker/links.json"


def load():
    try: return json.loads(FILE.read_text())
    except Exception: return []

def save(items):
    FILE.parent.mkdir(parents=True, exist_ok=True)
    FILE.write_text(json.dumps(items, indent=2, ensure_ascii=False))

def normalize(url):
    url = url.strip()
    if not re.match(r"^[a-z][a-z0-9+.-]*://", url, re.I): url = "https://" + url
    u = urlparse(url)
    if not u.netloc: raise ValueError("Link no válido")
    return url

def default_title(url):
    u = urlparse(url)
    host = u.netloc.removeprefix("www.")
    last = [p for p in u.path.split("/") if p][-1:] 
    return host + (" / " + last[0] if last else "")

def main():
    a = sys.argv[1:]
    items = load()
    if not a:
        print(json.dumps({"links": items}, ensure_ascii=False)); return
    cmd = a[0]
    try:
        if cmd == "add":
            url = normalize(a[1])
            if any(i["url"] == url for i in items):
                print("Ese link ya está guardado"); sys.exit(1)
            title = (a[2].strip() if len(a) > 2 else "") or default_title(url)
            group = a[3].strip() if len(a) > 3 else ""
            items.append({"id": uuid.uuid4().hex[:8], "title": title, "url": url, "group": group})
            save(items); print("Guardado")
        elif cmd == "rm":
            n = len(items); items = [i for i in items if i["id"] != a[1]]
            save(items); print("Borrado" if len(items) < n else "No existe")
        elif cmd == "move":
            for i in items:
                if i["id"] == a[1]: i["group"] = a[2].strip()
            save(items); print("Movido")
        else:
            print(__doc__); sys.exit(1)
    except (IndexError, ValueError) as e:
        print("Error: " + (str(e) or "faltan argumentos")); sys.exit(1)

main()

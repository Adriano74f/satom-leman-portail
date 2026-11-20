#!/usr/bin/env python3
"""Test de charge minimal (bibliotheque standard uniquement).
Usage : charge.py <url> <nombre_requetes> <parallelisme>
Sortie JSON : requetes, erreurs_5xx, autres_erreurs, p50_ms, p95_ms, max_ms.
"""
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

URL, N, PAR = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
CTX = ssl.create_default_context()


def requete(_):
    debut = time.perf_counter()
    try:
        with urllib.request.urlopen(URL, timeout=10, context=CTX) as rep:
            rep.read()
            code = rep.status
    except urllib.error.HTTPError as err:
        code = err.code
    except Exception:  # timeout, reset...
        code = 0
    return code, (time.perf_counter() - debut) * 1000


with ThreadPoolExecutor(max_workers=PAR) as pool:
    resultats = list(pool.map(requete, range(N)))

durees = sorted(d for _, d in resultats)
centile = lambda p: round(durees[min(len(durees) - 1, int(len(durees) * p))], 1)
print(json.dumps({
    "requetes": N,
    "erreurs_5xx": sum(1 for c, _ in resultats if 500 <= c < 600),
    "autres_erreurs": sum(1 for c, _ in resultats if c == 0 or 400 <= c < 500),
    "p50_ms": centile(0.50),
    "p95_ms": centile(0.95),
    "max_ms": round(durees[-1], 1),
}))

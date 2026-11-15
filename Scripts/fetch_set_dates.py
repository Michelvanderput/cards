#!/usr/bin/env python3
"""Haalt de releasedatum van elke TCGdex-set op. Schrijft set_dates.json ({setId: 'YYYY-MM-DD'}) naast dit script.
Gebruik: python3 Scripts/fetch_set_dates.py <uitvoermap>"""
import json, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor
out = sys.argv[1] if len(sys.argv) > 1 else "."
def get(url):
    for _ in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cards-app-mapbuilder"}), timeout=30) as r:
                return json.load(r)
        except Exception: pass
sets = get("https://api.tcgdex.net/v2/en/sets")
def one(s):
    d = get(f"https://api.tcgdex.net/v2/en/sets/{s['id']}") or {}
    return s["id"], d.get("releaseDate")
with ThreadPoolExecutor(8) as ex:
    dates = {i: d for i, d in ex.map(one, sets) if d}
json.dump(dates, open(f"{out}/set_dates.json", "w"))
print(len(dates), "van", len(sets), "sets met releasedatum")

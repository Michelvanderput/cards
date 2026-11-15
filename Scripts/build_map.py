import json, sys, os, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
S = os.path.dirname(os.path.abspath(__file__))
API = "https://api.tcgdex.net/v2/en"
def get(url):
    for i in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cards-app-mapbuilder"}), timeout=30) as r:
                return json.load(r)
        except Exception as e:
            time.sleep(1 + i)
    return None
sets = get(f"{API}/sets")
print("sets", len(sets), flush=True)
set_names = {s["id"]: s["name"] for s in sets}
def set_cards(sid):
    d = get(f"{API}/sets/{sid}")
    return [(c["id"], sid) for c in (d or {}).get("cards", [])]
with ThreadPoolExecutor(8) as ex:
    cards = [c for r in ex.map(set_cards, set_names) for c in r]
print("cards", len(cards), flush=True)
cache_path = f"{S}/cards3.jsonl"
done = {}
if os.path.exists(cache_path):
    for l in open(cache_path):
        j = json.loads(l); done[j["id"]] = j
todo = [c for c in cards if c[0] not in done]
print("todo", len(todo), flush=True)
def fetch(c):
    d = get(f"{API}/cards/{c[0]}")
    if not d: return None
    prods = set()
    for v in d.get("variants_detailed", []) or []:
        tp = (v.get("thirdParty") or {}).get("cardmarket")
        if tp: prods.add(tp)
        cm = ((v.get("pricing") or {}).get("cardmarket") or {}).get("idProduct")
        if cm: prods.add(cm)
    # Variantlabel per Cardmarket-product: normaal = geen label; anders type/stempel/foilpatroon.
    FOIL = {"pokeball": "Poké Ball", "masterball": "Master Ball", "tinsel": "Tinsel"}
    labels = {}
    for v in d.get("variants_detailed", []) or []:
        pid = (v.get("thirdParty") or {}).get("cardmarket") or ((v.get("pricing") or {}).get("cardmarket") or {}).get("idProduct")
        if not pid: continue
        if v.get("type") == "normal" and not v.get("foil") and not v.get("stamp"):
            labels[pid] = ""            # basisproduct
            continue
        parts = []
        if v.get("type") == "reverse": parts.append("Reverse holo")
        elif v.get("type") == "holo": parts.append("Holo")
        sub = v.get("subtype")
        if sub and sub != "unlimited" and not str(sub)[0].isdigit(): parts.append(str(sub).replace("-", " ").capitalize())
        for st in v.get("stamp") or []: parts.append(str(st).replace("-", " ").capitalize())
        if v.get("foil"): parts.append(FOIL.get(v["foil"], str(v["foil"]).capitalize()))
        label = " · ".join(parts)
        if labels.get(pid) != "": labels.setdefault(pid, label)
    img = d.get("image")
    atk = [a.get("name") for a in (d.get("attacks") or []) if a.get("name")]
    return {"id": c[0], "set": c[1], "name": d.get("name"), "atk": atk, "img": img.replace("https://assets.tcgdex.net/", "") if img else None, "prods": sorted(prods), "var": {str(k): v for k, v in labels.items()}}
n = 0
with open(cache_path, "a") as f, ThreadPoolExecutor(12) as ex:
    for r in ex.map(fetch, todo):
        if r: f.write(json.dumps(r) + "\n"); f.flush()
        n += 1
        if n % 1000 == 0: print(n, flush=True)
print("done", flush=True)
json.dump(set_names, open(f"{S}/set_names.json", "w"))

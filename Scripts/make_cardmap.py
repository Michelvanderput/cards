#!/usr/bin/env python3
"""Combineert cards2.jsonl (uit build_map.py) met de Cardmarket-productlijst tot Cards/Resources/cardmap.json.
1. Exacte koppeling: TCGdex kent het Cardmarket idProduct.
2. Aanvulling: naam + aanvalsnamen uit de Cardmarket-naam ("Pikachu [Thunder Shock]").
3. Trainers/energy zonder aanvallen: alleen op naam.
Gebruik: python3 Scripts/make_cardmap.py <cards2.jsonl> <set_names.json> <products_singles_6.json>"""
import json, re, sys
from collections import Counter, defaultdict

cards_path, sets_path, products_path = sys.argv[1:4]
set_names = json.load(open(sets_path))
products = json.load(open(products_path))["products"]
cards = [json.loads(l) for l in open(cards_path)]

def key(s):
    s = s.lower().replace("é", "e").replace("♂", "m").replace("♀", "f")
    s = re.sub(r"\blv\.?\s*\d+\b", "", s)        # "Lv.8" (oude sets)
    return re.sub(r"[^a-z0-9]", "", s)           # "Dragonite-GX" == "Dragonite GX"

def split_name(n):
    n = re.sub(r"\s*\((v\.\s*\d+|version\s*\w+)\)\s*$", "", n, flags=re.I)
    m = re.match(r"^(.*?)\s*\[(.*)\]\s*$", n)
    if not m: return key(n), None
    return key(m.group(1)), {key(t) for t in m.group(2).split("|")}

def set_path(img):  # "en/base/base1/4" -> "en/base/base1"
    return img.rsplit("/", 1)[0]

# --- 1. exact
prod_exp = {p["idProduct"]: p["idExpansion"] for p in products}
images, votes, path_votes = {}, defaultdict(Counter), defaultdict(Counter)
for c in cards:
    for pid in c["prods"]:
        if c["img"]: images[pid] = c["img"]
        exp = prod_exp.get(pid)
        if exp:
            votes[exp][set_names[c["set"]]] += 1
            if c["img"]: path_votes[exp][set_path(c["img"])] += 1
exact_ids = sorted(images)
exact = len(images)

# --- 2/3. naam (+ aanvallen)
by_base = defaultdict(list)
for c in cards:
    if c["img"] and c["name"]:
        by_base[key(c["name"])].append((c, {key(a) for a in c["atk"]}))
fuzzy_votes, fuzzy_paths = defaultdict(Counter), defaultdict(Counter)
for p in products:
    pid = p["idProduct"]
    if pid in images: continue
    base, tokens = split_name(p["name"])
    cands = by_base.get(base, [])
    if tokens is not None:
        cands = [c for c, atk in cands if atk <= tokens]
        best = max(cands, key=lambda c: len(c["atk"]), default=None)
    else:
        cands = [c for c, atk in cands if not atk]   # trainer/energy: geen aanvallen
        best = cands[0] if cands else None
    if not best: continue
    images[pid] = best["img"]
    if len({c["set"] for c in cands}) == 1:
        fuzzy_votes[p["idExpansion"]][set_names[cands[0]["set"]]] += 1
        fuzzy_paths[p["idExpansion"]][set_path(best["img"])] += 1

# --- setnamen en -logo's
sets = {str(e): v.most_common(1)[0][0] for e, v in votes.items()}
set_paths = {str(e): v.most_common(1)[0][0] for e, v in path_votes.items()}
size = Counter(p["idExpansion"] for p in products)
for e, v in fuzzy_votes.items():
    if str(e) in sets: continue
    name, n = v.most_common(1)[0]
    if n >= 5 and n / size[e] >= 0.6:
        sets[str(e)] = name
        set_paths[str(e)] = fuzzy_paths[e].most_common(1)[0][0]

json.dump({"sets": sets, "setPaths": set_paths,
           "images": {str(k): v for k, v in images.items()}, "exact": exact_ids},
          open("Cards/Resources/cardmap.json", "w"), separators=(",", ":"))
total = len(products)
print(f"images: {len(images)}/{total} ({100*len(images)/total:.1f}%), waarvan exact {exact}; "
      f"sets: {len(sets)}/{len(size)} expansions, producten met setnaam: "
      f"{100*sum(size[int(e)] for e in sets)/total:.0f}%, logo's: {len(set_paths)}")

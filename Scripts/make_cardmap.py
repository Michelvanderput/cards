#!/usr/bin/env python3
"""Combineert cards2.jsonl (uit build_map.py) met de Cardmarket-productlijst tot Cards/Resources/cardmap.json.
1. Exacte koppeling: TCGdex kent het Cardmarket idProduct.
2. Aanvulling: naam + aanvalsnamen uit de Cardmarket-naam ("Pikachu [Thunder Shock]").
Gebruik: python3 Scripts/make_cardmap.py <cards2.jsonl> <set_names.json> <products_singles_6.json>"""
import json, re, sys
from collections import Counter, defaultdict

cards_path, sets_path, products_path = sys.argv[1:4]
set_names = json.load(open(sets_path))
products = json.load(open(products_path))["products"]
cards = [json.loads(l) for l in open(cards_path)]

def norm(s):
    s = s.lower().replace("é", "e").replace("♂", "m").replace("♀", "f")
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]", "", s)).strip()

def split_name(n):
    n = re.sub(r"\s*\((v\.\s*\d+|version\s*\w+)\)\s*$", "", n, flags=re.I)
    m = re.match(r"^(.*?)\s*\[(.*)\]\s*$", n)
    if not m: return norm(n), set()
    return norm(m.group(1)), {norm(t) for t in m.group(2).split("|")}

# --- 1. exact
prod_exp = {p["idProduct"]: p["idExpansion"] for p in products}
images, votes = {}, defaultdict(Counter)
for c in cards:
    for pid in c["prods"]:
        if c["img"]: images[pid] = c["img"]
        if pid in prod_exp: votes[prod_exp[pid]][set_names[c["set"]]] += 1
exact = len(images)
exact_ids = sorted(images)   # alleen deze producten zijn exact gekoppeld (TCGdex kent het Cardmarket-id)

# --- 2. naam + aanvallen
by_base = defaultdict(list)
for c in cards:
    if c["img"] and c["name"]:
        by_base[norm(c["name"])].append((c, {norm(a) for a in c["atk"]}))
fuzzy_votes = defaultdict(Counter)
for p in products:
    pid = p["idProduct"]
    if pid in images: continue
    base, tokens = split_name(p["name"])
    cands = [c for c, atk in by_base.get(base, []) if atk <= tokens]
    if not cands: continue
    # voorkeur: kaart met de meeste aanvallen (specifiekste match)
    best = max(cands, key=lambda c: len(c["atk"]))
    images[pid] = best["img"]
    if len({c["set"] for c in cands}) == 1:
        fuzzy_votes[p["idExpansion"]][set_names[cands[0]["set"]]] += 1

# --- setnamen
sets = {str(e): v.most_common(1)[0][0] for e, v in votes.items()}
size = Counter(p["idExpansion"] for p in products)
for e, v in fuzzy_votes.items():
    if str(e) in sets: continue
    name, n = v.most_common(1)[0]
    if n >= 5 and n / size[e] >= 0.6: sets[str(e)] = name

json.dump({"sets": sets, "images": {str(k): v for k, v in images.items()}, "exact": exact_ids},
          open("Cards/Resources/cardmap.json", "w"), separators=(",", ":"))
total = len(products)
print(f"images: {len(images)}/{total} ({100*len(images)/total:.0f}%), waarvan exact {exact}; "
      f"sets: {len(sets)}/{len(size)} expansions, dekking producten met setnaam: "
      f"{100*sum(size[int(e)] for e in sets)/total:.0f}%")

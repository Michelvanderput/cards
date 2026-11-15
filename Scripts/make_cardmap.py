#!/usr/bin/env python3
"""Combineert cards2.jsonl (uit build_map.py) met de Cardmarket-productlijst tot Cards/Resources/cardmap.json.
1. Exacte koppeling: TCGdex kent het Cardmarket idProduct.
2. Aanvulling: naam + aanvalsnamen uit de Cardmarket-naam ("Pikachu [Thunder Shock]").
3. Trainers/energy zonder aanvallen: alleen op naam.
Gebruik: python3 Scripts/make_cardmap.py <cards2.jsonl> <set_names.json> <products_singles_6.json> [set_dates.json]"""
import json, re, sys
from collections import Counter, defaultdict

cards_path, sets_path, products_path = sys.argv[1:4]
dates_path = sys.argv[4] if len(sys.argv) > 4 else None
set_dates_by_id = json.load(open(dates_path)) if dates_path else {}
set_names = json.load(open(sets_path))
products = json.load(open(products_path))["products"]
cards = [json.loads(l) for l in open(cards_path)]

def key(s):
    s = s.lower().replace("é", "e").replace("♂", "m").replace("♀", "f")
    s = re.sub(r"\blv\.?\s*\d+\b", "", s)        # "Lv.8" (oude sets)
    s = re.sub(r"\bδ?\s*delta species\b", "", s)  # Cardmarket plakt "δ Delta Species" achter kaartnamen
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
variants = {}
for c in cards:
    for pid, label in (c.get("var") or {}).items():
        if label: variants[pid] = label      # leeg = gewone kaart, dus niet opslaan
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

# --- 4. set per expansie via overlap van kaartnamen (robuuster dan stemmen)
# Voor elke Cardmarket-expansie: welke TCGdex-set bevat de meeste van zijn producten (naam + aanvallen)?
tc_count = Counter(c["set"] for c in cards)
set_path_of = {}
for c in cards:
    if c["img"]: set_path_of.setdefault(c["set"], set_path(c["img"]))
cards_by_base = defaultdict(list)
for c in cards:
    if c["name"]: cards_by_base[key(c["name"])].append((c["set"], {key(a) for a in c["atk"]}))
hits = defaultdict(Counter)           # expansie -> set -> aantal producten dat in die set voorkomt
for p in products:
    base, tokens = split_name(p["name"])
    for t in {t for t, atk in cards_by_base.get(base, []) if tokens is None or atk <= tokens}:
        hits[p["idExpansion"]][t] += 1
size = Counter(p["idExpansion"] for p in products)
assign = {}                            # expansie -> (set, aandeel producten, dekking van de set)
for e, cnt in hits.items():
    t, h = cnt.most_common(1)[0]
    if size[e] >= 15 and h / size[e] >= 0.6 and tc_count[t]:
        assign[e] = (t, h / size[e], h / tc_count[t])

# --- setnamen en -logo's: overlap wint; anders de eerdere stemmen
sets = {str(e): v.most_common(1)[0][0] for e, v in votes.items()}
set_paths = {str(e): v.most_common(1)[0][0] for e, v in path_votes.items()}
for e, v in fuzzy_votes.items():
    if str(e) in sets: continue
    name, n = v.most_common(1)[0]
    if n >= 5 and n / size[e] >= 0.6:
        sets[str(e)] = name
        set_paths[str(e)] = fuzzy_paths[e].most_common(1)[0][0]
for e, (t, ratio, cover) in assign.items():
    sets[str(e)] = set_names[t]
    if t in set_path_of: set_paths[str(e)] = set_path_of[t]

# Hoofdset (Engelse uitvoering): per TCGdex-set de expansions met minstens 80% dekking (anders de beste).
# Japanse en andere uitvoeringen dekken meestal maar een deel en blijven daardoor apart.
by_set = defaultdict(list)
for e, (t, ratio, cover) in assign.items(): by_set[t].append((cover, e))
main = []
exact_set = set(exact_ids)
exp_exact = Counter(p["idExpansion"] for p in products if p["idProduct"] in exact_set)
for t, lst in by_set.items():
    full = [e for cover, e in lst if cover >= 0.8]
    if len(full) > 1:
        # Meerdere expansions dekken de set volledig (bijv. een Japanse uitvoering met dezelfde kaarten):
        # de exact gekoppelde (Engelse) delen winnen; zonder die: het laagste, oudste expansion-nummer.
        strong = [e for e in full if exp_exact[e] / size[e] >= 0.3]
        full = strong if strong else [min(full)]
    main += full if full else [max(lst)[1]]
# Benoemde expansions zonder overlap-toewijzing: grootste deel per naam, tenzij de naam al een hoofdset heeft.
covered = {sets[str(e)] for e in main}
unassigned = defaultdict(list)
for e, n in sets.items():
    if int(e) not in assign: unassigned[n].append(int(e))
for n, ids in unassigned.items():
    if n not in covered: main.append(max(ids, key=lambda e: size[e]))
main = sorted(set(main))
set_dates = {path: set_dates_by_id[path.rsplit("/", 1)[1]] for path in set(set_paths.values()) if path.rsplit("/", 1)[1] in set_dates_by_id}
json.dump({"sets": sets, "setPaths": set_paths, "setDates": set_dates, "variants": variants, "main": main,
           "images": {str(k): v for k, v in images.items()}, "exact": exact_ids},
          open("Cards/Resources/cardmap.json", "w"), separators=(",", ":"))
total = len(products)
print(f"images: {len(images)}/{total} ({100*len(images)/total:.1f}%), waarvan exact {exact}; "
      f"sets: {len(sets)}/{len(size)} expansions, producten met setnaam: "
      f"{100*sum(size[int(e)] for e in sets)/total:.0f}%, logo's: {len(set_paths)}, datums: {len(set_dates)}, varianten: {len(variants)}, hoofdsets: {len(main)}")
